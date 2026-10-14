package com.pvideocompress.pure_compress

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.media.MediaMuxer
import android.view.Surface
import java.io.File
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean

/// Hardware video encoder discovery + a decode→encode→mux MediaCodec
/// pipeline. Used for lossy H.264/HEVC/AV1 encoding only; stream copy and
/// software lossless encoding stay on the FFmpeg path.
object MediaCodecEncoder {

    private val wantedMimes = setOf("video/avc", "video/hevc", "video/av01")

    /// Every hardware video encoder the device advertises for the codecs we
    /// care about, with the MIME type, supported size and bitrate ranges,
    /// color formats and profiles — straight from MediaCodecList.
    fun listEncoders(): List<Map<String, Any?>> {
        val out = ArrayList<Map<String, Any?>>()
        for (info in MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos) {
            if (!info.isEncoder) continue
            for (type in info.supportedTypes) {
                if (type !in wantedMimes) continue
                val caps = try {
                    info.getCapabilitiesForType(type)
                } catch (_: Exception) {
                    continue // codec advertises the type but cannot report caps
                }
                val vc = caps.videoCapabilities ?: continue
                out.add(
                    mapOf(
                        "name" to info.name,
                        "mime" to type,
                        "widthMin" to vc.supportedWidths.lower,
                        "widthMax" to vc.supportedWidths.upper,
                        "heightMin" to vc.supportedHeights.lower,
                        "heightMax" to vc.supportedHeights.upper,
                        "bitrateMin" to vc.bitrateRange.lower,
                        "bitrateMax" to vc.bitrateRange.upper,
                        "colorFormats" to caps.colorFormats.toList(),
                        "profiles" to caps.profileLevels.map { it.profile }.distinct(),
                    )
                )
            }
        }
        return out
    }

    class EncodeException(val code: String, message: String) : Exception(message)

    data class Outcome(
        val cancelled: Boolean,
        val audioIncluded: Boolean,
        val droppedAudio: String?,
    )

    /// Single-job transcoder: video decoder renders straight into the
    /// encoder's input surface; encoder output is muxed to MP4 with
    /// MediaMuxer. Source resolution, frame rate and rotation metadata are
    /// preserved; AAC/MP3 audio is copied through, other audio is dropped
    /// and reported. Never lossy-claiming: the caller verifies the output.
    class Transcoder {
        private val cancelledFlag = AtomicBoolean(false)

        fun cancel() = cancelledFlag.set(true)

        fun encode(
            srcPath: String,
            outPath: String,
            targetMime: String,
            width: Int,
            height: Int,
            frameRate: Int,
            bitrateKbps: Int,
            onProgress: (Double) -> Unit,
        ): Outcome {
            cancelledFlag.set(false)
            val out = File(outPath)
            var muxerStarted = false
            var completed = false
            var framesWritten = 0L

            var videoExtractor: MediaExtractor? = null
            var audioExtractor: MediaExtractor? = null
            var decoder: MediaCodec? = null
            var encoder: MediaCodec? = null
            var muxer: MediaMuxer? = null
            var inputSurface: Surface? = null
            var audioIncluded = false
            var droppedAudio: String? = null

            try {
                // ---- inspect the source ------------------------------------
                videoExtractor = MediaExtractor().apply { setDataSource(srcPath) }
                var videoIndex = -1
                var srcMime = ""
                for (i in 0 until videoExtractor.trackCount) {
                    val mime = videoExtractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME)
                    if (mime != null && mime.startsWith("video/")) {
                        videoIndex = i
                        srcMime = mime
                        break
                    }
                }
                if (videoIndex < 0) {
                    throw EncodeException("no_video", "The source has no video stream.")
                }
                videoExtractor.selectTrack(videoIndex)
                val srcFormat = videoExtractor.getTrackFormat(videoIndex)
                val durationUs =
                    if (srcFormat.containsKey(MediaFormat.KEY_DURATION)) srcFormat.getLong(MediaFormat.KEY_DURATION)
                    else -1L
                val srcFps = if (srcFormat.containsKey(MediaFormat.KEY_FRAME_RATE))
                    srcFormat.getInteger(MediaFormat.KEY_FRAME_RATE) else frameRate
                val rotation = readRotation(srcPath)

                // ---- audio: copy AAC/MP3 through, report anything else -----
                audioExtractor = MediaExtractor().apply { setDataSource(srcPath) }
                var audioIndex = -1
                for (i in 0 until audioExtractor.trackCount) {
                    val mime = audioExtractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
                    if (!mime.startsWith("audio/")) continue
                    droppedAudio = mime // replaced below if the codec is copyable
                    if (mime == "audio/mp4a-latm" || mime == "audio/mpeg") {
                        audioIndex = i
                        droppedAudio = null
                    }
                    break // first audio track only
                }

                // ---- encoder: configure, then its input surface -------------
                val encFormat = MediaFormat.createVideoFormat(targetMime, width, height).apply {
                    setInteger(
                        MediaFormat.KEY_COLOR_FORMAT,
                        MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface
                    )
                    setInteger(MediaFormat.KEY_BIT_RATE, bitrateKbps * 1000)
                    setInteger(MediaFormat.KEY_FRAME_RATE, srcFps)
                    setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 2)
                }
                encoder = try {
                    MediaCodec.createEncoderByType(targetMime)
                } catch (e: Exception) {
                    throw EncodeException("no_codec", "No $targetMime encoder on this device: ${e.message}")
                }
                try {
                    encoder.configure(encFormat, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
                } catch (e: Exception) {
                    throw EncodeException(
                        "codec_failed",
                        "The device rejected the $targetMime encoder configuration: ${e.message}"
                    )
                }
                inputSurface = try {
                    encoder.createInputSurface()
                } catch (e: Exception) {
                    throw EncodeException("codec_failed", "Encoder input surface unavailable: ${e.message}")
                }
                encoder.start()

                // ---- decoder renders decoded frames into that surface ------
                decoder = MediaCodec.createDecoderByType(srcMime)
                decoder.configure(srcFormat, inputSurface, null, 0)
                decoder.start()

                // ---- muxer (starts once the encoder emits its format) ------
                muxer = MediaMuxer(outPath, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
                if (rotation == 0 || rotation == 90 || rotation == 180 || rotation == 270) {
                    muxer.setOrientationHint(rotation)
                }

                var videoTrack = -1
                var audioTrack = -1
                var inputDone = false
                var outputDone = false
                var lastVideoPts = -1L
                var lastAudioPts = -1L
                var lastPct = 0.0
                var lastPctAtMs = 0L

                val audioBuf: ByteBuffer? = if (audioIndex >= 0) {
                    val maxIn = audioExtractor.getTrackFormat(audioIndex)
                    ByteBuffer.allocate(
                        if (maxIn.containsKey(MediaFormat.KEY_MAX_INPUT_SIZE))
                            maxIn.getInteger(MediaFormat.KEY_MAX_INPUT_SIZE) else 256 * 1024
                    )
                } else null
                val aInfo = MediaCodec.BufferInfo()

                // Samples are held back until the video PTS passes them, so
                // the muxer receives the tracks interleaved in time order.
                fun drainAudioUpTo(maxPtsUs: Long) {
                    if (!muxerStarted || audioIndex < 0 || audioBuf == null || audioTrack < 0) return
                    while (!cancelledFlag.get()) {
                        audioBuf.clear()
                        val size = audioExtractor.readSampleData(audioBuf, 0)
                        if (size < 0) return
                        val pts = audioExtractor.sampleTime
                        val flags = audioExtractor.sampleFlags
                        if (pts > maxPtsUs) return // held back; not advanced
                        audioExtractor.advance()
                        if (pts <= lastAudioPts) continue // never go backwards
                        aInfo.offset = 0
                        aInfo.size = size
                        aInfo.presentationTimeUs = pts
                        aInfo.flags =
                            if (flags and MediaExtractor.SAMPLE_FLAG_SYNC != 0) MediaCodec.BUFFER_FLAG_KEY_FRAME else 0
                        audioBuf.position(0)
                        audioBuf.limit(size)
                        muxer.writeSampleData(audioTrack, audioBuf, aInfo)
                        lastAudioPts = pts
                    }
                }

                val dInfo = MediaCodec.BufferInfo()
                val eInfo = MediaCodec.BufferInfo()

                while (!outputDone) {
                    if (cancelledFlag.get()) {
                        return Outcome(true, audioIncluded, droppedAudio)
                    }

                    // 1. feed the decoder from the source video track
                    if (!inputDone) {
                        val inIdx = decoder.dequeueInputBuffer(10_000)
                        if (inIdx >= 0) {
                            val inBuf = decoder.getInputBuffer(inIdx)!!
                            val size = videoExtractor.readSampleData(inBuf, 0)
                            if (size < 0) {
                                decoder.queueInputBuffer(inIdx, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                                inputDone = true
                            } else {
                                decoder.queueInputBuffer(inIdx, 0, size, videoExtractor.sampleTime, 0)
                                videoExtractor.advance()
                            }
                        }
                    }

                    // 2. decoder output: rendered into the encoder surface
                    val dIdx = decoder.dequeueOutputBuffer(dInfo, 10_000)
                    if (dIdx >= 0) {
                        val eos = dInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                        decoder.releaseOutputBuffer(dIdx, !eos)
                        if (eos) encoder.signalEndOfInputStream()
                    }

                    // 3. encoder output: muxed (audio interleaved by PTS)
                    val eIdx = encoder.dequeueOutputBuffer(eInfo, 10_000)
                    when {
                        eIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                            val encOut = encoder.outputFormat
                            videoTrack = muxer.addTrack(encOut)
                            if (audioIndex >= 0 && audioBuf != null) {
                                audioTrack = muxer.addTrack(audioExtractor.getTrackFormat(audioIndex))
                                audioIncluded = true
                            }
                            muxer.start()
                            muxerStarted = true
                        }
                        eIdx >= 0 -> {
                            val eBuf = encoder.getOutputBuffer(eIdx)!!
                            val isConfig = eInfo.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0
                            if (eInfo.size > 0 && !isConfig) {
                                if (eInfo.presentationTimeUs <= lastVideoPts) {
                                    eInfo.presentationTimeUs = lastVideoPts + 1 // stay monotonic
                                }
                                lastVideoPts = eInfo.presentationTimeUs
                                drainAudioUpTo(eInfo.presentationTimeUs)
                                eBuf.position(eInfo.offset)
                                eBuf.limit(eInfo.offset + eInfo.size)
                                muxer.writeSampleData(videoTrack, eBuf, eInfo)
                                framesWritten++
                                if (durationUs > 0) {
                                    val pct = (eInfo.presentationTimeUs.toDouble() / durationUs).coerceIn(0.0, 1.0)
                                    val now = System.currentTimeMillis()
                                    if (pct - lastPct >= 0.01 || now - lastPctAtMs >= 500) {
                                        lastPct = pct
                                        lastPctAtMs = now
                                        onProgress(pct)
                                    }
                                }
                            }
                            val eos = eInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0
                            encoder.releaseOutputBuffer(eIdx, false)
                            if (eos) outputDone = true
                        }
                    }
                }

                // flush any audio the interleaver still holds back
                drainAudioUpTo(Long.MAX_VALUE)

                if (framesWritten == 0L) {
                    throw EncodeException(
                        "no_output",
                        "The hardware encoder produced no frames. This device rejected the stream."
                    )
                }
                completed = true
                return Outcome(false, audioIncluded, droppedAudio)
            } catch (e: EncodeException) {
                throw e
            } catch (e: IllegalStateException) {
                // Codec died mid-stream — the classic device-specific failure.
                throw EncodeException("codec_failed", "The hardware encoder stopped: ${e.message}")
            } finally {
                // Release every codec/surface/muxer/extractor, in order.
                try { decoder?.stop() } catch (_: Exception) {}
                try { decoder?.release() } catch (_: Exception) {}
                try { encoder?.stop() } catch (_: Exception) {}
                try { encoder?.release() } catch (_: Exception) {}
                try { inputSurface?.release() } catch (_: Exception) {}
                try { if (muxerStarted) muxer?.stop() } catch (_: Exception) {}
                try { muxer?.release() } catch (_: Exception) {}
                try { videoExtractor?.release() } catch (_: Exception) {}
                try { audioExtractor?.release() } catch (_: Exception) {}
                if (!completed) out.delete() // never leave partial output
            }
        }

        private fun readRotation(path: String): Int {
            val mmr = MediaMetadataRetriever()
            return try {
                mmr.setDataSource(path)
                (mmr.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION) ?: "0").toInt()
            } catch (_: Exception) {
                0
            } finally {
                try { mmr.release() } catch (_: Exception) {}
            }
        }
    }
}

import 'models.dart';

/// Preset compression profile offering curated starting configurations.
enum CompressionProfile {
  high('High', 'Maximum quality, preserves original up to 4K'),
  medium('Medium', 'Balanced quality-to-size, up to 1080p'),
  low('Low', 'Maximum space savings, up to 720p');

  const CompressionProfile(this.label, this.description);
  final String label;
  final String description;
}

/// A named, reusable compression preset with target size and video parameters.
class CompressionPreset {
  const CompressionPreset({
    required this.id,
    required this.name,
    this.description = '',
    this.targetSizeBytes,
    this.profile,
    this.videoCodec = VideoCodecOption.h264,
    this.targetWidth,
    this.targetHeight,
    this.frameRate,
    this.audio = AudioAction.copySource,
    this.container = ContainerOption.mp4,
    this.crf,
    this.speedPreset = SpeedPreset.medium,
    this.quality = QualityPreset.balanced,
    this.isBuiltIn = false,
  });

  final String id;
  final String name;
  final String description;
  final int? targetSizeBytes;
  final CompressionProfile? profile;
  final VideoCodecOption videoCodec;
  final int? targetWidth;
  final int? targetHeight;
  final double? frameRate;
  final AudioAction audio;
  final ContainerOption container;
  final int? crf;
  final SpeedPreset speedPreset;
  final QualityPreset quality;
  final bool isBuiltIn;

  double? get targetSizeMB =>
      targetSizeBytes == null ? null : targetSizeBytes! / (1024 * 1024);

  CompressionPreset copyWith({
    String? id,
    String? name,
    String? description,
    int? targetSizeBytes,
    CompressionProfile? profile,
    VideoCodecOption? videoCodec,
    int? targetWidth,
    int? targetHeight,
    double? frameRate,
    AudioAction? audio,
    ContainerOption? container,
    int? crf,
    SpeedPreset? speedPreset,
    QualityPreset? quality,
    bool? isBuiltIn,
    bool clearTargetSize = false,
    bool clearResolution = false,
    bool clearFrameRate = false,
    bool clearCrf = false,
  }) {
    return CompressionPreset(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      targetSizeBytes:
          clearTargetSize ? null : (targetSizeBytes ?? this.targetSizeBytes),
      profile: profile ?? this.profile,
      videoCodec: videoCodec ?? this.videoCodec,
      targetWidth:
          clearResolution ? null : (targetWidth ?? this.targetWidth),
      targetHeight:
          clearResolution ? null : (targetHeight ?? this.targetHeight),
      frameRate: clearFrameRate ? null : (frameRate ?? this.frameRate),
      audio: audio ?? this.audio,
      container: container ?? this.container,
      crf: clearCrf ? null : (crf ?? this.crf),
      speedPreset: speedPreset ?? this.speedPreset,
      quality: quality ?? this.quality,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'description': description,
        'targetSizeBytes': targetSizeBytes,
        'profile': profile?.name,
        'videoCodec': videoCodec.name,
        'targetWidth': targetWidth,
        'targetHeight': targetHeight,
        'frameRate': frameRate,
        'audio': audio.name,
        'container': container.name,
        'crf': crf,
        'speedPreset': speedPreset.name,
        'quality': quality.name,
        'isBuiltIn': isBuiltIn,
      };

  factory CompressionPreset.fromJson(Map<String, dynamic> json) {
    return CompressionPreset(
      id: json['id'] as String,
      name: json['name'] as String,
      description: json['description'] as String? ?? '',
      targetSizeBytes: json['targetSizeBytes'] as int?,
      profile: json['profile'] != null
          ? CompressionProfile.values.asNameMap()[json['profile']]
          : null,
      videoCodec:
          VideoCodecOption.values.asNameMap()[json['videoCodec']] ??
              VideoCodecOption.h264,
      targetWidth: json['targetWidth'] as int?,
      targetHeight: json['targetHeight'] as int?,
      frameRate: (json['frameRate'] as num?)?.toDouble(),
      audio: AudioAction.values.asNameMap()[json['audio']] ??
          AudioAction.copySource,
      container:
          ContainerOption.values.asNameMap()[json['container']] ??
              ContainerOption.mp4,
      crf: json['crf'] as int?,
      speedPreset:
          SpeedPreset.values.asNameMap()[json['speedPreset']] ??
              SpeedPreset.medium,
      quality: QualityPreset.values.asNameMap()[json['quality']] ??
          QualityPreset.balanced,
      isBuiltIn: json['isBuiltIn'] as bool? ?? false,
    );
  }

  static const List<CompressionPreset> builtInPresets = [
    CompressionPreset(
      id: 'builtin_github_10mb',
      name: 'GitHub',
      description: '10 MB limit for GitHub issue & PR attachments',
      targetSizeBytes: 10 * 1024 * 1024,
      profile: CompressionProfile.low,
      videoCodec: VideoCodecOption.h264,
      targetWidth: 1280,
      targetHeight: 720,
      audio: AudioAction.aac128,
      container: ContainerOption.mp4,
      isBuiltIn: true,
    ),
    CompressionPreset(
      id: 'builtin_discord_20mb',
      name: 'Discord Free',
      description: '20 MB limit for free Discord accounts',
      targetSizeBytes: 20 * 1024 * 1024,
      profile: CompressionProfile.medium,
      videoCodec: VideoCodecOption.h264,
      targetWidth: 1920,
      targetHeight: 1080,
      audio: AudioAction.aac128,
      container: ContainerOption.mp4,
      isBuiltIn: true,
    ),
    CompressionPreset(
      id: 'builtin_email_25mb',
      name: 'Email',
      description: '25 MB standard email attachment ceiling',
      targetSizeBytes: 25 * 1024 * 1024,
      profile: CompressionProfile.medium,
      videoCodec: VideoCodecOption.h264,
      targetWidth: 1920,
      targetHeight: 1080,
      audio: AudioAction.aac128,
      container: ContainerOption.mp4,
      isBuiltIn: true,
    ),
    CompressionPreset(
      id: 'builtin_discord_nitro_basic_50mb',
      name: 'Discord Nitro Basic',
      description: '50 MB upload limit for Nitro Basic',
      targetSizeBytes: 50 * 1024 * 1024,
      profile: CompressionProfile.medium,
      videoCodec: VideoCodecOption.h264,
      targetWidth: 1920,
      targetHeight: 1080,
      audio: AudioAction.aac128,
      container: ContainerOption.mp4,
      isBuiltIn: true,
    ),
    CompressionPreset(
      id: 'builtin_messenger_100mb',
      name: 'Messenger',
      description: '100 MB upload limit for Messenger',
      targetSizeBytes: 100 * 1024 * 1024,
      profile: CompressionProfile.medium,
      videoCodec: VideoCodecOption.h264,
      audio: AudioAction.copySource,
      container: ContainerOption.mp4,
      isBuiltIn: true,
    ),
    CompressionPreset(
      id: 'builtin_discord_nitro_500mb',
      name: 'Discord Nitro',
      description: '500 MB upload limit for Discord Nitro',
      targetSizeBytes: 500 * 1024 * 1024,
      profile: CompressionProfile.high,
      videoCodec: VideoCodecOption.h264,
      audio: AudioAction.copySource,
      container: ContainerOption.mp4,
      isBuiltIn: true,
    ),
    CompressionPreset(
      id: 'builtin_x_standard_512mb',
      name: 'X Standard',
      description: '512 MB limit for standard X (Twitter) accounts',
      targetSizeBytes: 512 * 1024 * 1024,
      profile: CompressionProfile.high,
      videoCodec: VideoCodecOption.h264,
      audio: AudioAction.copySource,
      container: ContainerOption.mp4,
      isBuiltIn: true,
    ),
    CompressionPreset(
      id: 'builtin_whatsapp_telegram_4gb',
      name: 'WhatsApp / Telegram',
      description: '4 GB document limit for WhatsApp & Telegram',
      targetSizeBytes: 4 * 1024 * 1024 * 1024,
      profile: CompressionProfile.high,
      videoCodec: VideoCodecOption.hevc,
      audio: AudioAction.copySource,
      container: ContainerOption.mp4,
      isBuiltIn: true,
    ),
    CompressionPreset(
      id: 'builtin_x_premium_8gb',
      name: 'X Premium',
      description: '8 GB upload limit for X Premium subscribers',
      targetSizeBytes: 8 * 1024 * 1024 * 1024,
      profile: CompressionProfile.high,
      videoCodec: VideoCodecOption.hevc,
      audio: AudioAction.copySource,
      container: ContainerOption.mp4,
      isBuiltIn: true,
    ),
  ];
}

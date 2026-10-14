import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pure_compress/main.dart';
import 'package:pure_compress/ui/screens/onboarding_screen.dart';

void main() {
  testWidgets('First launch displays onboarding', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PureCompressApp());
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsOneWidget);
    expect(find.text('Welcome to PureCompress'), findsOneWidget);
    expect(find.text('Next'), findsOneWidget);
    expect(find.text('Skip'), findsOneWidget);
  });

  testWidgets('Onboarding Next and Back navigation works', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PureCompressApp());
    await tester.pumpAndSettle();

    // Slide 1 -> Slide 2
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Select Your Video'), findsOneWidget);
    expect(find.text('Back'), findsOneWidget);

    // Slide 2 -> Back to Slide 1
    await tester.tap(find.text('Back'));
    await tester.pumpAndSettle();
    expect(find.text('Welcome to PureCompress'), findsOneWidget);

    // Slide 1 -> Slide 2 -> Slide 3 -> Slide 4
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Choose Your Mode'), findsOneWidget);

    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(find.text('Process, Verify & Save'), findsOneWidget);
    expect(find.text('Get Started'), findsOneWidget);
  });

  testWidgets('Skip enters main app and persists completion', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PureCompressApp());
    await tester.pumpAndSettle();

    await tester.tap(find.text('Skip'));
    await tester.pumpAndSettle();

    expect(find.text('Select video'), findsOneWidget);
    expect(find.text('Exact Lossless'), findsOneWidget);
    expect(find.text('High Efficiency'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);

    final isCompleted = await OnboardingScreen.isCompleted();
    expect(isCompleted, isTrue);
  });

  testWidgets('Subsequent launch skips onboarding directly to Home',
      (tester) async {
    SharedPreferences.setMockInitialValues({
      OnboardingScreen.prefKey: true,
    });
    await tester.pumpWidget(const PureCompressApp());
    await tester.pumpAndSettle();

    expect(find.byType(OnboardingScreen), findsNothing);
    expect(find.text('Select video'), findsOneWidget);
    expect(find.text('Exact Lossless'), findsOneWidget);
    expect(find.text('High Efficiency'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.textContaining('processed entirely on this device'),
        findsOneWidget);
  });
}

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:pure_compress/main.dart';

void main() {
  testWidgets('Home screen renders core elements', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const PureCompressApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Select video'), findsOneWidget);
    expect(find.text('Exact Lossless'), findsOneWidget);
    expect(find.text('High Efficiency'), findsOneWidget);
    expect(find.text('Custom'), findsOneWidget);
    expect(find.textContaining('processed entirely on this device'),
        findsOneWidget);
  });
}

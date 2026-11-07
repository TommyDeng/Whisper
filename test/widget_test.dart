import 'package:flutter_test/flutter_test.dart';
import 'package:whisper/ui/main_app.dart';

void main() {
  testWidgets('shows whisper app shell', (tester) async {
    await tester.pumpWidget(const WhisperApp());

    expect(find.text('联系人').first, findsOneWidget);
  });
}

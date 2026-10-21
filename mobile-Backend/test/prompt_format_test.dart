import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_backend_pipeline/mobile_backend_pipeline.dart';
void main() {
  test('Gemma instructions share the initial user turn', () {
    final prompt = formatOnDevicePrompt(PromptFormatKind.gemma, 'Rules', 'Source');
    expect('<start_of_turn>user'.allMatches(prompt), hasLength(1));
    expect(prompt, contains('Rules\n\nSource'));
    expect(prompt, endsWith('<start_of_turn>model\n'));
  });
}

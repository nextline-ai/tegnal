import 'package:flutter_test/flutter_test.dart';
import 'package:tegnal/core/support/l10n.dart';

void main() {
  test('Korean word joining leaves template placeholders intact', () {
    final joined = L10n.keepingWords('{reel1} 이미지를 {reel2} 방식으로 모작하세요. 목표: {goal}.');

    final names = RegExp(r'\{([^{}]*)\}').allMatches(joined).map((match) => match[1]).toList();
    expect(names, ['reel1', 'reel2', 'goal']);
    expect(joined, contains('이⁠미⁠지⁠를'));
  });
}

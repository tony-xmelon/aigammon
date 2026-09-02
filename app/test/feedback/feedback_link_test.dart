import 'package:aigammon_app/feedback/feedback_link.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  group('buildFeedbackIssueUri', () {
    test('produces the exact URL for a known version and platform', () {
      final uri = buildFeedbackIssueUri(
        appVersion: '0.12.0',
        platform: 'android',
      );

      // Spelled out in full, once. The pieces are asserted individually below;
      // this is the assertion that catches a change to the SHAPE — a moved
      // repo, a dropped label, a body that stopped being escaped.
      expect(
        uri.toString(),
        'https://github.com/tony-xmelon/aigammon/issues/new'
        '?title=%5BFeedback%5D+AI+Gammon+0.12.0+%28android%29'
        '&body=%23%23%23+What+happened%3F%0A%0A%3C%21--+Describe+the+problem+'
        'or+the+idea.+--%3E%0A%0A%23%23%23+Details%0A%0A-+App+version%3A+0.12.0'
        '%0A-+Platform%3A+android%0A'
        '&labels=enhancement',
      );
    });

    test('points at the issues form of the right repository', () {
      final uri =
          buildFeedbackIssueUri(appVersion: '1.0.0', platform: 'ios');
      expect(uri.scheme, 'https');
      expect(uri.host, 'github.com');
      expect(uri.path, '/tony-xmelon/aigammon/issues/new');
      // `enhancement` and not `feedback`: GitHub silently drops a `labels=`
      // value that does not exist on the repository, and `feedback` does not
      // exist on tony-xmelon/aigammon while `enhancement` (a default label)
      // does. A label that vanishes on submit is worse than no label.
      expect(uri.queryParameters['labels'], 'enhancement');
    });

    test('the decoded body carries the version and platform', () {
      final uri =
          buildFeedbackIssueUri(appVersion: '9.9.9', platform: 'windows');
      final body = uri.queryParameters['body']!;
      expect(body, contains('- App version: 9.9.9'));
      expect(body, contains('- Platform: windows'));
      expect(uri.queryParameters['title'],
          '[Feedback] AI Gammon 9.9.9 (windows)');
    });

    test('no diagnostics section when there is no excerpt', () {
      for (final excerpt in [null, '', '   \n  ']) {
        final uri = buildFeedbackIssueUri(
          appVersion: '0.12.0',
          platform: 'android',
          diagnosticsExcerpt: excerpt,
        );
        expect(uri.queryParameters['body'], isNot(contains('Diagnostics')),
            reason: 'excerpt: ${excerpt == null ? 'null' : '"$excerpt"'}');
      }
    });

    test('an excerpt lands in a fenced block', () {
      final uri = buildFeedbackIssueUri(
        appVersion: '0.12.0',
        platform: 'android',
        diagnosticsExcerpt: 'StateError: boom\n#0  main',
      );
      final body = uri.queryParameters['body']!;
      expect(body, contains('### Diagnostics'));
      expect(body, contains('```\nStateError: boom\n#0  main\n```'));
    });

    test('a long excerpt is truncated so the URL stays usable', () {
      // GitHub's issue form is a GET. An over-long URL is not truncated
      // gracefully — it is rejected — so the excerpt has to be cut here.
      final uri = buildFeedbackIssueUri(
        appVersion: '0.12.0',
        platform: 'android',
        diagnosticsExcerpt: 'x' * 100000,
      );
      final body = uri.queryParameters['body']!;
      expect(body, contains('(truncated'));
      expect(body.length, lessThan(2000));
      // And the whole percent-encoded URL stays inside the practical browser
      // limit, which is the property that actually matters.
      expect(uri.toString().length, lessThan(8000));
    });
  });

  group('currentPlatformName', () {
    test("names the running platform with Flutter's own spelling", () {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(currentPlatformName(), 'windows');
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(currentPlatformName(), 'android');
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(currentPlatformName(), 'iOS');
    });
  });
}

/// Application identity shown in About and reports.
library;

const String appName = 'SI Studio';

/// Keep in step with `version:` in pubspec.yaml.
const String appVersion = '0.8.0';

/// Source repository.
const String repoUrl = 'https://github.com/rinzlerz/SI-Analysis-Studio';

/// Published web app (GitHub Pages); share links from Android point here.
const String webAppUrl = 'https://rinzlerz.github.io/SI-Analysis-Studio/';

/// Android test builds (GitHub Releases).
const String releasesUrl = '$repoUrl/releases/latest';

/// Where testers send feedback: an e-mail (mailto:you@example.com), a form
/// or a GitHub Issues URL. Leave empty to hide the feedback buttons. The
/// GitHub issue form (.github/ISSUE_TEMPLATE/feedback.yml) is pre-filled
/// with the app version, platform and analysis link.
const String feedbackUrl = '$repoUrl/issues/new?template=feedback.yml';

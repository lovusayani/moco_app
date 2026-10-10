/// Platform hooks for Moco Live: opening the provider's page and hosting the
/// official Stripchat player. Real on web; inert stubs elsewhere (Live is a
/// web feature, and Android never compiles the browser interop).
library;

export 'live_platform_stub.dart'
    if (dart.library.js_interop) 'live_platform_web.dart';

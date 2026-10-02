{{flutter_js}}
{{flutter_build_config}}

// Moco's loader. Flutter's own (deprecated) service worker is deliberately not
// passed to the loader — it unregisters itself on activate and would remove
// the app's real worker, web/sw.js, which owns installability and the offline
// app shell. sw.js is network-first, so a deploy is picked up on the next load
// without any build-version plumbing.
(function () {
  if ('serviceWorker' in navigator && window.isSecureContext) {
    window.addEventListener('load', function () {
      navigator.serviceWorker
        .register('sw.js', { scope: './' })
        .catch(function (err) {
          console.warn('Moco service worker registration failed', err);
        });
    });
  }

  function hideSplash() {
    var splash = document.getElementById('moco-splash');
    if (!splash) return;
    splash.classList.add('hidden');
    setTimeout(function () { splash.remove(); }, 250);
  }

  _flutter.loader.load({
    config: {
      // Serve CanvasKit from this origin instead of Google's CDN, so the
      // installed app shell works without third-party requests and can be
      // cached by sw.js.
      canvasKitBaseUrl: 'canvaskit/',
    },
    onEntrypointLoaded: async function (engineInitializer) {
      var appRunner = await engineInitializer.initializeEngine();
      await appRunner.runApp();
      hideSplash();
    },
  });
})();

// Which of the app's three themes a Keycloak page shows (D-616 of the finance repository's UX-15): the cookie ft_theme
// that the app writes on a choice (D-617; its frontend/src/theme.ts), when it is blue, light or dark; otherwise the
// device, dark giving Blue and light or none Light, as the app's public/theme.js decides with nothing chosen. It sets
// data-theme on <html>, which css/tokens.css reads, and follows the device's changes while there is no cookie. On the
// sign-in pages it is a classic script in the head (theme.properties' scripts), so it runs before the first paint; the
// account console loads the same file as a module, deferred (css/tokens.css follows the device until then).
(function () {
  var QUERY = '(prefers-color-scheme: dark)'

  function chosen() {
    var parts = document.cookie ? document.cookie.split(';') : []
    for (var i = 0; i < parts.length; i++) {
      var pair = parts[i].split('=')
      if (pair[0].trim() === 'ft_theme') {
        var value = (pair[1] || '').trim()
        if (value === 'blue' || value === 'light' || value === 'dark') return value
      }
    }
    return null
  }

  function device() {
    try {
      return window.matchMedia(QUERY).matches ? 'blue' : 'light'
    } catch (e) {
      return 'light'
    }
  }

  function apply() {
    document.documentElement.setAttribute('data-theme', chosen() || device())
  }

  apply()
  try {
    // Only matters while there is no cookie: apply takes the cookie first.
    window.matchMedia(QUERY).addEventListener('change', apply)
  } catch (e) {
    // No media queries: the theme stays as set.
  }
})()

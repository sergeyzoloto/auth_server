<#--
  Finance Tracker's layout for every HTML email (the finance repository's UX-15, D-620), in place of Keycloak's
  html/template.ftl; the email templates themselves, their bodies (Keycloak's texts, with the realm's name) and every
  plain-text version stay Keycloak's. Inline styles only, Light's colours in every client, and no web font loaded.

  A body's link is Keycloak's own <a> in its own <p>: it becomes the button, and the plain link follows it in 13px.
  The body is Keycloak's sanitized HTML (kcSanitize); only that <a>'s own attributes are rewritten.
-->
<#macro emailLayout>
<#assign font = "'IBM Plex Sans', Arial, Helvetica, sans-serif">
<#assign body><#nested></#assign>
<#assign body = body?markup_string>
<#assign p = "margin:0 0 16px;">
<#assign button = "display:inline-block;padding:10px 18px;background:#5B48D6;color:#FFFFFF;border-radius:6px;font-weight:600;text-decoration:none;font-family:" + font + ";">
<#assign plain = "display:block;margin:8px 0 0;font-size:13px;line-height:18px;color:#566173;word-break:break-all;">
<#assign body = body?replace('<p>', '<p style="' + p + '">')>
<#assign body = body?replace('<a href="([^"]*)"([^>]*)>(.*?)</a>', '<a href="$1"$2 style="' + button + '">$3</a><span style="' + plain + '"><a href="$1" style="color:#566173;text-decoration:underline;">$1</a></span>', 'r')>
<html lang="${locale.language}" dir="${(ltr)?then('ltr','rtl')}">
<head>
<meta charset="utf-8">
<meta name="color-scheme" content="light only">
<meta name="supported-color-schemes" content="light">
</head>
<body style="margin:0;padding:0;background:#F4F6F9;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#F4F6F9;">
<tr><td align="center" style="padding:24px 12px;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;background:#FFFFFF;border:1px solid #D5DCE6;border-radius:8px;border-collapse:separate;">
<tr><td style="padding:20px 28px 16px;border-bottom:1px solid #D5DCE6;font-family:${font};font-size:16px;line-height:24px;font-weight:600;color:#1B2433;">Finance Tracker</td></tr>
<tr><td style="padding:24px 28px 8px;font-family:${font};font-size:15px;line-height:23px;color:#1B2433;">${body?no_esc}</td></tr>
<tr><td style="padding:16px 28px 20px;border-top:1px solid #D5DCE6;font-family:${font};font-size:12px;line-height:18px;color:#566173;">Sent by Finance Tracker&rsquo;s sign-in. If you didn&rsquo;t expect it, you can ignore it.</td></tr>
</table>
</td></tr>
</table>
</body>
</html>
</#macro>

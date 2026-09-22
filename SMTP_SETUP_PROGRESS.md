# SMTP setup: progress and resume notes

**Last updated:** 2026-09-22
**Status:** working. Keycloak `myapps` sends mail through Brevo, and the
password-reset flow was tested end to end against the Supabase database. What
is left depends on the production host, which doesn't exist yet: steps A and B
below. The procedure itself now lives in [PRODUCTION.md](PRODUCTION.md), step
*5. Set up email* — those changes are not committed yet.
**Goal (reached):** Keycloak realm `myapps` sends email (password reset,
optionally email verification) through Brevo. *Email (SMTP)* is out of
*Not covered yet* in PRODUCTION.md.

No secrets in this file. The SMTP key lives in a password manager and in
Keycloak, never in the repo.

## Accounts and where things live

| What | Where |
|---|---|
| Domain `finance-nl.com` | Bought 2026-09-21 through Google Workspace. Registrar: Squarespace Domains. Expires 2027-09-21. Billing and renewal: Google Admin console |
| DNS for the domain | Squarespace, not Google Admin: [squarespace.com/login](https://squarespace.com/login) → *Continue with Google* → *Domains → finance-nl.com → DNS → DNS Settings → Custom records* |
| Mailbox | `serge@finance-nl.com` (Google Workspace) |
| SMTP provider | Brevo, organization `finance-tracker`. Domains and senders: *Settings → Senders, domains, IPs*. SMTP: *Settings → SMTP & API → SMTP* |
| SMTP key and Login | Password manager. Rotating them: PRODUCTION.md → *Operations* |
| Live SMTP settings | Keycloak realm `myapps`, *Realm settings → Email*. Stored in Supabase, not in any file |

## Done 2026-09-22
- [x] Brevo activated the SMTP platform; SMTP key generated and stored in the
  password manager, together with the Brevo *Login*.
- [x] Keycloak configured: admin email in `master`, SMTP in `myapps`
  (`smtp-relay.brevo.com:587`, StartTLS, authentication on, From
  `no-reply@finance-nl.com`), *Test connection* passed.
- [x] *Forgot password* turned on in `myapps` (*Realm settings → Login*).
- [x] Reset password tested end to end: the mail arrived, the link worked, and
  the event is in Supabase.
- [x] Brevo shows the domain authenticated and `no-reply@finance-nl.com`
  verified — implied by the delivered, DKIM-signed mail.
- [x] DNS rechecked on `nsb1.squarespacedns.com` and on `1.1.1.1`: all Brevo
  records unchanged and visible publicly.
- [x] Port 587 to `smtp-relay.brevo.com` open from the laptop.
- [x] PRODUCTION.md: added *5. Set up email* (old steps 5–6 became 6–7), the
  reset-mail check in *Verify*, SMTP key rotation under *Operations*, SMTP
  symptoms under *Troubleshooting*; removed Email from *Not covered yet*.
  **Uncommitted.**

This ran on the laptop: the prod stack (`auth-server-prod`) with
`AUTH_HOSTNAME=localhost`, against the Supabase database. Because every realm
setting lives in that database, the SMTP configuration and the *Forgot
password* flag carry over to the real host as they are. Only the hostname in
the links changes.

`realm-prod.json` still has `resetPasswordAllowed: false`, on purpose: it is
read only on a first start, where there is no SMTP yet. The live realm in the
database has it on.

## Still to do

### A. On the production host, once it exists
```bash
timeout 5 bash -c 'exec 3<>/dev/tcp/smtp-relay.brevo.com/587' && echo ok
```
No `ok` means the hosting provider blocks outgoing SMTP; ask them to unblock
it. Keycloak itself needs no change: it picks the settings up from the
database.

### B. DNS record for the auth server
`auth.finance-nl.com` has no A/AAAA record yet (checked 2026-09-22). In
Squarespace, add `A` with host `auth` pointing at the server's IPv4 address,
and `AAAA` if it has IPv6. Let's Encrypt needs these before the first start
(PRODUCTION.md, *Prerequisites*).

Then redo the reset-password test against `https://auth.finance-nl.com`: until
the hostname changes, the links in the mail point at `localhost`.

### C. Open decision: Verify email
Off unless you turned it on. Once it's on, every user with *Email verified =
off* has to verify at their next login, so check who that affects first:
```sql
select u.username, u.email
from keycloak.user_entity u join keycloak.realm r on r.id = u.realm_id
where r.name = 'myapps' and u.service_account_client_link is null and not u.email_verified;
```

### D. Not verified by a lookup
- [ ] Workspace alias `no-reply@finance-nl.com` delivers to `serge@` (send it
  a test email). Only matters for replies: Keycloak sends *from* that address,
  it never reads it.

## Reference

### DNS records in place (checked 2026-09-22)

| Type | Host | Value | Owner |
|---|---|---|---|
| MX | `@` | `1 smtp.google.com` | Google, don't touch |
| TXT | `@` | `v=spf1 include:_spf.google.com ~all` | Google, don't touch |
| TXT | `google._domainkey` | Google DKIM key | Google, don't touch |
| TXT | `@` | `brevo-code:e1af9fc289533f30b126ae65c069eb2b` | Brevo |
| CNAME | `brevo1._domainkey` | `b1.finance-nl-com.dkim.brevo.com` | Brevo |
| CNAME | `brevo2._domainkey` | `b2.finance-nl-com.dkim.brevo.com` | Brevo |
| TXT | `_dmarc` | `v=DMARC1; p=none; rua=mailto:rua@dmarc.brevo.com` | Brevo |

SPF stays Google-only on purpose. With Brevo's shared IPs, DMARC passes
through Brevo's DKIM signature. Keep a single `v=spf1` record.

Recheck:
```bash
NS=nsb1.squarespacedns.com
dig +short TXT finance-nl.com @$NS                      # 2 lines: v=spf1 … and brevo-code:…
dig +short CNAME brevo1._domainkey.finance-nl.com @$NS  # b1.finance-nl-com.dkim.brevo.com.
dig +short CNAME brevo2._domainkey.finance-nl.com @$NS  # b2.finance-nl-com.dkim.brevo.com.
dig +short TXT _dmarc.finance-nl.com @$NS               # "v=DMARC1; p=none; …"
```

### If mail stops arriving
`docker compose -f docker-compose.prod.yml logs keycloak | grep -iE 'mail|smtp'`

| Symptom | Cause |
|---|---|
| `535` authentication failed | Wrong username (use Brevo's *Login*), or an API key (`xkeysib-`) instead of the SMTP key (`xsmtpsib-`) |
| Sender rejected / not verified | *From* isn't `no-reply@finance-nl.com`, or that sender lost its verification in Brevo |
| Timeout | Port 587 blocked on the host (A above), or SSL used instead of StartTLS |
| Quota exceeded | The Brevo free plan sends 300 emails a day |

## Later (2–4 weeks after go-live)
- Read the DMARC reports (Brevo collects them via `rua`). Once every
  legitimate sender passes, tighten DMARC to `p=quarantine`, then to
  `p=reject`.
- Before tightening, check that Gmail DKIM signing is on in Google Admin
  (*Apps → Google Workspace → Gmail → Authenticate email*). The
  `google._domainkey` record is already published.

# auth_server

Keycloak, Postgres and Caddy for `auth.finance-nl.com`. `PRODUCTION.md` is the
runbook, `deploy/` is what runs, and `change_log.mdx` records every task.

## Production safety

On 2026-09-28 (D4), a `sed` range that was meant to pull one command out of
`PRODUCTION.md` ran on to the end of the file. The extracted text went to bash
on the server, which ran restore steps, a key deletion and an upgrade. Markdown
prose ran too: the backticks of inline code turn prose into command
substitutions (`change_log.mdx`, D4-IR). Rules for every task:

- Never run text extracted from a document or file on a server: no `sed`,
  `awk` or `grep` output, and no variable filled from a file. Check a
  documented command by reading it, or by running it in a throwaway local
  container.
- Write every server command out explicitly on the command line. Never pipe a
  file or a heredoc into a remote shell (`ssh host bash -s < file`,
  `ssh host 'bash -s' <<'EOF'`, `… | ssh host bash`).
- Never run a runbook section that changes state (restore, rotate, delete,
  update) as a test. It runs only when the task is to do exactly that.
- Production is read-only by default, unless the task says otherwise.

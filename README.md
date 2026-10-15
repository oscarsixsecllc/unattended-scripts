# Unattended: companion scripts

These are the working scripts and cron jobs referenced in "Unattended" by Randy Hinders, with our real IDs, tokens, paths, and hostnames replaced by placeholders. They ran on the agent hosts the book describes. Chapter 6 promises the heartbeat check would be here; the other three are the ones that sit next to it in Appendix B.

Download, read every file once, replace the placeholders, run each script with `--dry-run`, and only then install the cron lines.

## What is in the archive

| File | What it does | Cadence | Book reference |
|---|---|---|---|
| `disk-cleanup.sh` | Journal vacuum, npm and pip cache purge, backup rotation | Weekly, Sunday 02:00 | Ch 6, Appendix B "Weekly disk-cleanup cron" |
| `disk-usage-post.sh` | Posts root filesystem usage to a Discord channel, with a warning threshold | Daily, 16:00 | Ch 6, Appendix B "Daily disk-usage report" |
| `heartbeat-check.sh` | Verifies the alert channel still receives alerts; warns through a different channel if not | Every 6 hours | Ch 6 "'Are you still there?' heartbeat check", Appendix B |
| `security-audit.sh` | Ports, crontab drift, processes, SSH failures, sudo, disk, updates, unattended-upgrades, secrets file permissions | Every 4 hours | Ch 11 "Architecture and Infrastructure" (not printed in Appendix B) |
| `crontab.example` | The four cron lines, with the `%` escaping note | n/a | Appendix B |
| `SANITIZATION-NOTES.md` | What was stripped from the originals and what to put back | n/a | n/a |

Everything else in Appendix B (the prompts, checklists, the session size cap) is process description, not code. There is nothing to download for those; the printed text is the whole artifact.

## Expected environment

- Linux host with bash 4 or newer, `curl`, `ss`, `find`, `df`, and GNU `date`. Debian and Ubuntu are what these ran on.
- `security-audit.sh` uses `apt` and `dpkg` for the update checks. On other distributions those two checks are skipped.
- An account that can read `/var/log/auth.log` (usually membership in the `adm` group) or run `journalctl` for the SSH and sudo checks. Without that access those checks report nothing rather than failing.
- A Discord server where you control at least two channels: one alert channel and one fallback channel. Webhooks are created under channel settings, Integrations, Webhooks. The heartbeat check also needs a bot token with "View Channel" and "Read Message History" on the alert channel.

Nothing here requires root except the journal vacuum in `disk-cleanup.sh`, which uses `sudo -n` if available and otherwise skips that step.

## How to adapt

Every value you must change is written as `<PLACEHOLDER>` and has a `# TODO: reader` comment next to it. The scripts refuse to run while any placeholder is still in place, so a missed one fails loudly instead of posting to nowhere.

Find them all at once:

```
grep -n 'TODO: reader' *.sh crontab.example
```

| Placeholder | Where | Replace with |
|---|---|---|
| `<BACKUP_DIR>` | disk-cleanup.sh | Absolute path to the directory holding your backup archives |
| `<WEBHOOK_URL>` | disk-usage-post.sh, security-audit.sh | Discord webhook URL for the channel that should receive the post |
| `<DISCORD_BOT_TOKEN>` | heartbeat-check.sh | Token for a bot that can read your alert channel |
| `<ALERT_CHANNEL_ID>` | heartbeat-check.sh | Numeric ID of the alert channel (enable Developer Mode in Discord, right-click the channel, Copy Channel ID) |
| `<FALLBACK_WEBHOOK_URL>` | heartbeat-check.sh | Webhook for a different channel than the alert channel |
| `<CRONTAB_CANONICAL>` | security-audit.sh | Path to the committed copy of your crontab |
| `<INSTALL_DIR>`, `<LOG_DIR>` | crontab.example | Where you put the scripts and where logs should go |

You can also leave the placeholders in the files and set the same names as environment variables on the cron line. Either works. Do not put tokens in your shell profile expecting cron to see them; it will not.

Every script also has a short block of tunables near the top (retention days, thresholds, max age) with sane defaults. Change them after the first dry run tells you what normal looks like on your machine.

## Safety notes

1. **Dry-run first.** Every script accepts `--dry-run`. It performs the read-only parts, prints what it would delete or send, and changes nothing. Do this before the first real run and again after any edit.
2. **Test webhooks on a scratch channel.** Point `WEBHOOK_URL` at a throwaway channel until you have seen the message shape. Then move it.
3. **Exercise the failure path on purpose.** For the heartbeat check, run once with `MAX_AGE_HOURS=0` to force the stale path and confirm the fallback notice arrives. Run once with a wrong bot token to confirm the "cannot read" path also alerts. The book's May 14 lesson is that an alert channel can break silently; prove your fallback works before you need it.
4. **Accept baselines deliberately.** The first run of `security-audit.sh` records current ports and process names as the baseline and says so. Read that list. If something in it should not be running, fix it before you accept the baseline. Later, after a legitimate change, run `security-audit.sh --accept-baseline`.
5. **Do not point disk-cleanup at anything but a backup directory.** It deletes files older than the retention window under `BACKUP_DIR`, recursively. The script refuses a handful of obviously wrong paths, but that is a guardrail, not a substitute for reading the value you typed.
6. **Keep your crontab in version control.** The security audit compares live against committed and tells you when they drift. That drift check is how you notice a job that was added or removed without you.
7. **Store secrets with mode 600.** The audit checks the paths in `SECRET_PATHS` and flags anything readable by group or others. Add your own secrets directories to that list.

## Where each file is discussed in the book

- **Chapter 6** tells the story of the disk filling up with no monitoring, the alert channel permissions breaking at the same time, and the fix: build the "are you still there?" check first, then the disk cleanup, the session cap, and the daily usage post.
- **Chapter 11** describes the architecture these run inside, including the version-controlled crontab and the security audit that runs every four hours.
- **Chapter 12** lists disk cleanup in the spin-up sequence for a new agent.
- **Appendix B**, "Scripts and Cron Jobs", prints the short versions of the first three and points here for the working copies. Section F, "Infrastructure discipline", is the one-line summary of why all four exist.

## License and warranty

Use, copy, and modify these freely. They are offered as working examples, not as a supported product. Read them before you run them. You are responsible for what they do on your machine.

Questions and corrections: oscarsixsecurityllc.com/unattended

## How the scripts talk to Discord

Posting is the same everywhere: a `curl` POST of a small JSON body to a channel webhook (`WEBHOOK_URL`, or `FALLBACK_WEBHOOK_URL` in the heartbeat check). Webhooks need no bot and no permissions beyond creating the webhook on the channel.

`heartbeat-check.sh` is the one exception, and only on the read side: it has to read the newest message in the alert channel, and a webhook cannot read. So it carries a bot token (`DISCORD_BOT_TOKEN`) with View Channel and Read Message History on that one channel, and nothing else. Its notice still goes out through a webhook. If you ever see a script here using a bot token to post, that is a bug.

## Versions

Each script carries a `# Version:` line under the shebang. Check it before asking about behavior; the archive is re-published when anything changes.

- 1.1.1 (2026-10-15): LICENSE (Apache-2.0, Oscar Six Security LLC) added as the eighth file, matching the public repo at github.com/oscarsixsecllc/unattended-scripts; archive contents now unpack into a versioned folder (unattended-scripts-1.1.1/) instead of loose files. No functional changes.
- 1.1.0 (2026-10-14): version lines added to every script and to crontab.example; transport note added to heartbeat-check.sh and this README. No functional changes.
- 1.0.0 (2026-10-04): first published set (disk-cleanup, disk-usage-post, heartbeat-check, security-audit, crontab.example, sanitization notes).

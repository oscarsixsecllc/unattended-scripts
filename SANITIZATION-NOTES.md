# Sanitization notes

What was removed from the live versions of these scripts before publishing, and what you should put in its place. If you are adapting these for your own host, this is the checklist of everything that was specific to ours.

## Placeholder mapping

| Placeholder | What was there originally | What you substitute |
|---|---|---|
| `<BACKUP_DIR>` | The backup directory on our hosts | Your backup archive directory, absolute path |
| `<WEBHOOK_URL>` | A live Discord webhook for our reporting or alert channel | A webhook you create on your own channel |
| `<DISCORD_BOT_TOKEN>` | The bot token our agent platform uses | A bot token with read access to your alert channel |
| `<ALERT_CHANNEL_ID>` | The numeric ID of our alert channel | Your alert channel's numeric ID |
| `<FALLBACK_WEBHOOK_URL>` | A webhook on a second channel | A webhook on a channel that is not your alert channel |
| `<CRONTAB_CANONICAL>` | The committed crontab copy inside our agent workspace repo | The path to your own committed crontab copy |
| `<INSTALL_DIR>` | The scripts directory inside our agent workspace | Wherever you unpack this archive |
| `<LOG_DIR>` | A state directory under the agent user's home | Any writable log directory |

## What was stripped, by category

**Paths.** Every absolute path under a real home directory was replaced. The live scripts referenced the agent user's home, a workspace repo checkout, and a per-agent state directory. Defaults now derive from `$HOME` or are placeholders.

**Hostnames.** The live scripts hardcoded or assumed our VM names. The published versions read `hostname -s` at runtime so the message labels itself correctly wherever it runs.

**Tokens and webhooks.** The live heartbeat check carried a real bot token and two real channel IDs. The live audit and usage post carried real webhook URLs. All replaced with placeholders; the scripts refuse to run until you fill them in.

**Channel IDs and channel names.** Discord channel IDs (long numeric strings) and our channel names were removed. Comments now say "alert channel" and "fallback channel" instead of naming ours.

**Delivery mechanism.** Our live versions post through the agent platform's own CLI, which knows our accounts. The published versions post with `curl` to a plain Discord webhook so they work without that platform installed. Same message, different transport.

**Port allowlists.** The live audit hardcoded the ports our agent gateway and browser relay listen on, and skipped listeners owned by those processes. The published version uses a baseline file instead: the first run records what is listening, you review it, and later runs report only what changed. That is more portable and does not leak which services we run.

**Service names.** The live audit checked the journal for crashes of one specific user service of ours. That check was dropped rather than genericized; it was tied to our stack.

**Secrets paths.** The live audit checked one specific scripts directory for world-writable files. The published version takes a `SECRET_PATHS` list, defaulting to `~/.ssh`, `~/.secrets`, and `~/.env`, and checks for anything readable by group or others.

**Repository names.** References to our private repositories, commit hashes, and the companion package's location in our source tree were removed from headers and comments.

**Emoji.** The live scripts prefixed findings with emoji. The published versions use bracketed tags like `[SSH]` and `[PORTS]` so the output is readable in a plain log file and greppable.

## What was added

Three things exist in the published versions that the live originals did not have, all in service of a reader running these cold:

1. `--dry-run` on every script.
2. A placeholder guard: each script exits with a clear message if any `<PLACEHOLDER>` is still in place.
3. Refusal to prune a short list of obviously wrong `BACKUP_DIR` values (`/`, `/home`, `/etc`, and so on) in `disk-cleanup.sh`.

## What was not changed

The checks themselves, the cadences, the dedup window on the audit (24 hours), the disk threshold default (85 percent), the backup retention default (30 days), and the journal cap (500M) are the values we run with.

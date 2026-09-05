---
summary: "Muse Code authentication and subscription window tracking."
read_when:
  - Configuring Muse Code in CodexBar
  - Debugging Muse Code login or subscription usage errors
---

# Muse Code

CodexBar shows Muse Code subscription usage: the rolling 5-hour window and the weekly window. It does **not** invent a request count, dollar spend, or local session-token history.

## Authentication

Sign in with the Muse CLI:

```bash
muse login
```

CodexBar reads the same Keychain item the CLI stores (`ai.meta.dev.credentials` / `meta`) and sends only the device-code `dca:` access token to `POST https://api.meta.ai/muse-code/key`. Meta dashboard `LLM_` keys and Muse-minted `LLM|` inference keys cannot read this quota (they 401 on that mint endpoint).

The CLI metadata file `~/.config/muse/auth.json` is used only to detect a Muse login. Override its path with `MUSE_AUTH_PATH` if needed. CodexBar never prompts Keychain.

## Data shown

- Plan name from `subs_tier_name` (for example Muse Code Power Usage).
- 5-hour window percent, duration, and `resets_at`.
- Weekly window percent and `resets_at`.

Pay-as-you-go accounts without `is_subs_active` are reported as having no subscription rather than a fake 0% bar. Accounts that still need a payment method are reported as billing-incomplete.

## Privacy

The mint response can include a card brand/last-four `payment_method` field. CodexBar does not display it. Email and plan stay on the Muse identity card.

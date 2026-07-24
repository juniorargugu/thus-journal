# Telegram menu-button → THUS Journal (entry shortcut only)

**Type:** operator setup notes. **Docs-only.** This changes **nothing** in code and does
**not** modify `thus-trading-bot`, the GUGU runtime, or any Journal data.

## What this is

A BotFather **menu button** that puts a one-tap shortcut to `https://thus999.com` at the
bottom of the Telegram chat with the bot. It is purely a **low-friction entry point** — a
link. It is **not**:

- a change to the bot's runtime or handlers,
- a Journal write from Telegram,
- a GUGU cognition change (cognition stays **frozen**; the bot stays **capture-only**),
- a Telegram Web App / mini-app (that is a **separate** future design — see below).

## Steps (in the Telegram app, chatting with @BotFather)

1. Open a chat with **@BotFather**.
2. Send `/setmenubutton`.
3. Select the target bot when prompted.
4. When asked for the **URL**, send:
   ```
   https://thus999.com
   ```
5. When asked for the **button text**, send a short label, e.g.:
   ```
   เปิด THUS
   ```
   (or `Open THUS`).
6. BotFather confirms. The button now appears next to the message input in that bot's chat.

To change or remove it later: re-run `/setmenubutton` and set a new URL/label, or choose the
default commands menu.

## Safety notes

- This is an **outbound link** to the existing production web app. No token, credential, or
  Journal data flows through the button.
- Tapping it opens `thus999.com` in Telegram's in-app browser (or the system browser). The
  user is still just using the normal web app — same durable-save path, same auth.
- **Do not** wire this to any bot command that writes to Supabase or the Journal.

## Out of scope (separate future design)

- A **Telegram Web App / mini-app** (rendering THUS *inside* Telegram, deep auth handoff,
  bot↔Journal messaging) is a distinct design that must go through its own review. It is
  **not** enabled or implied by this menu button.
- **Quick Capture** from Telegram (writing a draft trade from a chat message) is explicitly
  **not** built — see `artifacts/mobile_adoption/quick_capture_design_stub.md`.

# Dolce+ Apple Wallet card — setup (step 1 of 4)

This switches on the "card system" in the database. Nothing changes for clients yet:
there is no "Add to Apple Wallet" button until step 2, so no client can get a card.

You only need the Supabase website. It takes about 10 minutes. No passwords or keys are typed anywhere.

---

## Part A — Add the card tables (SQL Editor)

1. Open Supabase → your Dolce project → **SQL Editor** → **New query**.
2. Open the file `supabase_migration_wallet.sql` (in the dolce-app folder), select everything (⌘A), copy (⌘C) and paste it into the editor.
3. Press **Run**.
4. At the bottom you should see **one row**. Every column should say **true**:
   `tables_locked · points_trigger · client_trigger · push_link · daily_check`
5. Send me a screenshot of that row.

What it does: it creates the card tables (locked so the app can't read them), keeps each card in step with the client's points, level and name, and checks levels once a day.
It does not change any points, bookings or clients.

## Part B — Add the card "server" (Edge Function)

1. Supabase → **Edge Functions** → **Deploy a new function** → **Via Editor**.
2. Name it exactly: `wallet`
3. Delete the example code. Open `supabase/functions/wallet/index.ts` from the dolce-app folder. Select everything (⌘A), copy and paste it in.
   It's a long file because the card pictures are inside it. That's normal.
4. Press **Deploy**.
5. When it's deployed, open the function's **Details** (or **Settings**). Switch **OFF** "Verify JWT" / "Enforce JWT verification", then **Save**.
   This is needed because the iPhone's Wallet calls this server with its own card password, not a Dolce+ login. The server checks those passwords itself.
6. Send me a screenshot of the function page showing it's deployed and that JWT verification is off.

## Secrets

You don't need to add anything now. The server uses the Apple certificate saved during the Wallet test (the `WALLET_TEST_…` secrets).
Before we ever remove the test, we'll copy them to `WALLET_…` names. Don't delete any `WALLET_TEST_…` secret.

---

### Next (I do these)
- **Step 2:** the "Add to Apple Wallet" button in the client's Profile.
- **Step 3:** staff scan the QR with the iPhone Camera → that client's points open in Admin.
- **Step 4:** test on your iPhone with a test client, before any real client gets a card.

### Before launch (owner)
- Upgrade Supabase to the Pro plan.

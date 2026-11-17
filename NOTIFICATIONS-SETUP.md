# Dolce+ iPhone notifications — setup

When this is done, clients who use the iPhone app get a notification on their phone:
- **Booking confirmed:** when reception confirms their booking, with the date and time.
- **Reminders:** before the appointment (we suggest 24 hours and 2 hours before).
- **Cancelled / New time:** when reception cancels or moves an appointment.

The messages are in the client's language (English, Arabic or Kurdish). Sending them is free.

Clients are asked once, right after they book in the app, whether they want notifications. They can say no.

Never paste the Apple key or any secret into the chat or the app. They only go into Supabase → Secrets.

---

## 1. Apple notification key (about 5 minutes)
1. Go to developer.apple.com → **Account** → **Certificates, IDs & Profiles** → **Keys** → **+**.
2. Name: `Dolce Plus Push`. Tick **Apple Push Notifications service (APNs)**. Press **Configure** and choose **Sandbox & Production**, then **Save** → **Continue** → **Register**.
3. Press **Download**. Apple lets you download it **only once**: keep the `AuthKey_XXXXXXXXXX.p8` file safe, for example next to the Wallet keys in `~/DolceWalletKeys`.
4. Note the **Key ID**: the 10 characters shown on the page, which are also in the file name.

## 2. Supabase → Edge Functions → Secrets → add these 6
| Name | Value |
|---|---|
| `APNS_KEY` | Open the .p8 file in TextEdit and copy **everything**, including the BEGIN and END lines |
| `APNS_KEY_ID` | the Key ID from step 1 |
| `APNS_TEAM_ID` | `99KC6YBSL5` |
| `APNS_BUNDLE_ID` | `com.dolceclinic.plus` |
| `APNS_PRODUCTION` | `true` |
| `NOTIFY_CRON_SECRET` | In Terminal run `openssl rand -base64 32` and paste the result. Keep it open: step 4 needs the same value |

## 3. Database (SQL Editor)
Run `supabase_migration_push_confirmed.sql`. The last row should show **true | true**.

## 4. Start the sending
1. Open `supabase_cron_notifications.sql`. Replace `PASTE-THE-SECRET-HERE` with the **same** value as `NOTIFY_CRON_SECRET`, keeping the quotes.
2. Run it.
3. Don't save the file with the secret in it. Close it **without saving**.

## 5. The sender (Edge Function)
1. Edge Functions → **Deploy a new function** → **Via Editor**. Name it `notify-dispatch`.
2. Paste `supabase/functions/notify-dispatch/index.ts` → **Deploy**.
3. Settings → **Verify JWT OFF** → Save.

## 6. Xcode (version 1.0.1)
1. Open the project. Click **App** (blue icon) → **Signing & Capabilities**. You should now see **Push Notifications** in the list. I've already added it.
2. **Product → Archive** → Distribute → App Store Connect → Upload.

## 7. Switch it on (Admin → Settings → Automatic messages)
1. Tick **Send messages automatically**.
2. How to reach clients: **iPhone app notifications**.
3. Reminders: add **24 hours before** and **2 hours before**.
4. Keep the three boxes ticked (confirmed, cancellations, new time).
5. **Save**.

## 8. Test before submitting to Apple
1. Install the uploaded 1.0.1 from **TestFlight** on your iPhone.
2. Log in as yourself, book something, and allow notifications.
3. In Admin, **Confirm** that booking. Within about 2 minutes your iPhone should show "Your appointment at … is confirmed ✅".
4. Then cancel the test booking.

Notifications sent from a version run straight from Xcode won't arrive, because Apple uses a separate test channel for those. TestFlight and App Store versions work.

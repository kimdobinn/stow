# Firebase setup for Stow (one time, ~5 minutes)

Stow uses a free Firebase project of your own to pass messages between the Mac and the phone.
Everything is on the free **Spark** plan; never upgrade it.

## 1. Create the project

1. Open <https://console.firebase.google.com> and sign in with your Google account.
2. **Create a project** → name it `stow` (any name works).
3. Turn **off** Google Analytics → **Create project**.

## 2. Firestore (the shared database)

1. Left menu: **Build › Firestore Database** → **Create database**.
2. Edition: **Standard**. Database ID: leave it as `(default)`.
3. Location: the region closest to you (for example `asia-southeast1` Singapore). It can't be changed later.
4. Start in **production mode** → **Create**.
5. Open the **Rules** tab, replace everything with the contents of
   [`firestore.rules`](firestore.rules) (in this folder) → **Publish**.

## 3. Anonymous sign-in (for the phone)

1. **Build › Authentication** → **Get started**.
2. **Sign-in method** tab → **Anonymous** → turn on **Enable** → **Save**.

The phone only gets access after you pair it by scanning the QR code on the Mac.

## 4. The Mac's key

1. Gear icon (top left) → **Project settings** → **Service accounts** tab.
2. **Firebase Admin SDK** → **Generate new private key** → **Generate key**.
   A `.json` file downloads.
3. Leave it in Downloads. In Stow, open **Phone** and click **Choose Key File…**.
   Stow copies it into its own folder; then delete the one in Downloads.

This key is a password for the whole project: don't share it or paste it into a chat.

## 5. The Android app (for later)

1. **Project settings › General** → **Add app** → Android icon.
2. Package name: `dev.stow.android`, nickname `Stow` → **Register app**.
3. Download `google-services.json` and save it as `~/alt-tube/firebase/google-services.json`.
4. Skip the remaining steps (Claude adds the SDK) → **Continue to console**.

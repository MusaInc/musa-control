# External TestFlight (friends): ready-to-paste

Existing app record (bundle `uk.co.musastudios.musacontrol`). Nothing here creates a new app.

## Order of steps

1. `bash deploy/install-cloud.sh`: account service live at `https://musastudios.co.uk/control-cloud`
   (privacy and support pages included). Add `~/.config/musa-control-cloud/apns.json` for push.
2. `bash deploy/review-demo/setup.sh`: reviewer account + sandboxed demo computer. The sign-in is written to
   `~/.config/musa-control-cloud/review-account.txt`.
3. A green build: `gh workflow run ios.yml --ref multi-user -f testflight=false` (on the public repo if you
   published it with `tools/publish_public_repo.sh`, otherwise after fixing MusaInc billing).
4. Upload: `gh workflow run ios.yml --ref multi-user -f testflight=true -f version=0.4.0`.
5. App Store Connect → TestFlight → External Testing → **+** group "Friends" → add build 0.4.0 → fill in the fields
   below → Submit for Beta App Review → once approved, add testers by email or turn on a public link.

## Test Information

**Beta App Description**
> Musa Control lets you run and supervise AI coding agents (Claude Code, Codex, Gemini CLI) on your own computers
> from an iPad or iPhone. Connect a Linux server, Mac or Windows PC (WSL), sign the AI tools in with your own
> subscriptions, then start sessions, watch their progress, review screenshots, previews and diffs, approve or
> reject their actions, and use terminals, files and git. Work keeps running on your computer when the app is closed.

**What to Test**
> Connect a computer (Add a computer), sign in to an AI tool under Machines & AI, start an agent task, and try
> approving an action from the app and from a notification. Tell us what was confusing.

**Feedback email**: support@musastudios.co.uk
**Marketing URL**: https://musastudios.co.uk/control-cloud/support
**Privacy Policy URL**: https://musastudios.co.uk/control-cloud/privacy

**Sign-in required**: Yes. Use the email and password from `review-account.txt`.

**Review Notes**
> Sign in with "Continue with email" using the account provided. It has one linked demo computer ("Demo computer"),
> a sandboxed Linux container with a sample project. Open it in the sidebar, then try Terminal, Files and Git.
>
> Musa Control controls computers that belong to the user. It doesn't provide AI services or sell credits: Claude
> Code, Codex and Gemini CLI run on the user's computer and sign in there with each provider's own login. The app
> never asks for a provider password. Commands run only on the user's own computer, the AI tools' own approval
> prompts stay in force, and risky actions need an explicit confirmation in the app.
>
> Account deletion: Machines & AI → Account → Manage → Delete account. Sign in with Apple is offered on the first screen.

## Answers for the review questions

* **Encryption**: uses only standard protocols (HTTPS/TLS and SSH), so the app is exempt
  (`ITSAppUsesNonExemptEncryption = false`). Confirm this before public App Store release.
* **Account deletion in app**: yes (above). **Sign in with Apple**: yes (any third-party/email sign-in requires it).
* **Third-party content / remote code**: the app doesn't download or run code itself. It sends user-typed
  commands to the user's own computer (like any SSH client).

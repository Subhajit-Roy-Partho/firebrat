# Firebrat Community

Free, copyright-free audiobook library. Static Vite site + Firestore metadata; every audiobook file is hosted on the
Internet Archive. Design/data model: `SPEC.md`. Rules: `../firebase/firestore.rules`, indexes: `../firebase/firestore.indexes.json`.

```sh
npm install
npm test            # pure Internet Archive / manifest helpers
npm run dev
VITE_APP_BASE=/firebrat/community/ npm run build   # -> dist/, publish at <pages>/community/
```

## One-time setup (not done automatically)
1. `firebase deploy --only firestore:rules,firestore:indexes` (project `firebrat-8c597`). Until then the site shows "You need to sign in".
2. Console -> Firestore: create doc `admins/<your-uid>` (any fields) to unlock `#/admin` (takedowns, reports, bugs, moderation).
3. Replace `takedown@REPLACE-ME.example` in `src/views/legal.js` and designate a DMCA agent if you operate in the US.
4. Authorize your Pages domain under Firebase Auth -> Settings -> Authorized domains.
5. Copy `dist/` into the Pages mirror under `community/` (same flow as `../site/README.md`).

## Notes
- IA `/download` does not send CORS headers, so the chapter list is read from the submitter's local file and stored in Firestore.
- Direct browser upload to IA uses the submitter's own S3 keys (memory only). Preflight to s3.us.archive.org returned CORS-open; a real upload is untested.
- Rules are unit-untested: run them in the Firestore emulator before going public. No rate limiting without Functions.

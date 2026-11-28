# Week Summary — Speaker Script

**Deck:** `Vault_Week_Summary_Presentation.pptx` — 8 slides
**Topic:** the week of 23–28 November 2026 — service-to-service identity with Vault
**Total target:** 4:00 (plus Q&A)

This is the short recap deck. It walks the same week the main
`MLflow_Exact_Stack_V2_Presentation.pptx` now tells on its new slide 6, but from the
inside: what the problem was, what the chain looks like, what refused, what broke.

Everything below is spoken text. Anything in *italics* is a stage direction, not a line.

---

## Speaker plan

| Speaker | Slides | Section | Target | Cumulative |
|---|---|---|---|---|
| Khon Sotheara | 1–2 | Title + the problem | 0:55 | 0:55 |
| Khann Udomvirak | 3–4 | The chain + the proof | 1:10 | 2:05 |
| Chea Sela | 5 | What went wrong | 0:45 | 2:50 |
| Theng Sivchheng | 6–8 | The deck, the scope, close | 1:10 | 4:00 |

All four stay for Q&A. Sivchheng leads and takes the last question.

Rules for the room:

- Do not re-explain the architecture. Slide 2 is the only place it appears, and only as before/after.
- Say a number only if you can point at the command behind it. Every figure on these slides was measured on the running stack on 27–28 November.
- If you are behind on time, cut slide 5's fifth bullet, not slide 4. The refusals are the point.

---

## Slide 1 — Title: "One key per service" (Sotheara)

*On screen: deck title, the week, the seven tags (Vault · AppRole · Policy · Bucket · Restart · Slide · PR #4).*
*Time: 0:15.*

> This is the small deck for this week only. Last week we had a working lakehouse and MLflow
> demo. The professor asked one question about it that we could not answer: **where does
> service-to-service identity live in this stack?**
>
> This week's answer is on the title slide. Not one shared key with two owners — **one key per
> service.** Seven minutes of work later, that is what the demo does, and these eight slides are
> the evidence.

*Cue:* "It started from a bad design, so let me show you that first."

---

## Slide 2 — 01 · The problem: "One key was doing everything" (Sotheara)

*On screen: BEFORE / AFTER cards; closing line "Same demo as before — 2,500 rows, same dashboard. Only the credential path moved."*
*Time: 0:40.*

> Before this week there was no service-to-service identity at all. There was **one** rendered
> credentials file. It held a single MinIO key, it sat in a Docker volume called `vault-creds`,
> and the Nessie container and the MLflow container both mounted that same file.
>
> So both applications could read both buckets. Data for the BI path and artifacts for the model
> path were reachable by the same credential. Nothing recorded who read what, and a leaked file
> was a leaked lakehouse — that file was the whole storage layer.
>
> The right-hand column is the fix. `vault-init` now writes one key per service **plus** a policy
> that can read only that service's path. Each consumer logs in with its own AppRole and renders
> only its own key. And MinIO enforces the same split with a bucket-scoped user per service, so
> even bypassing Vault does not give you the neighbour's bucket.
>
> One thing to be clear about: the demo the audience saw did not change. Same 2,500 rows, same
> dashboard, same model. Only the credential path moved.

*Cue:* "Here is the chain that makes that true."

---

## Slide 3 — 02 · What we built: "Four stages of init" (Udomvirak)

*On screen: four numbered cards — Secrets, Storage, Credentials, Services — and the banner "Five one-shots in total · all exit 0 · no new image, no new port".*
*Time: 0:40.*

> Read it left to right, because that is exactly the order `docker compose` runs it in:
> Vault healthy, then init, then users, then credentials, then the services.
>
> **One, secrets.** `vault-init` is the only container that ever holds the root token. It writes
> `secret/lakehouse/s3/<service>`, a read-only policy for that path, and an AppRole — then it
> exits. The root token does not survive into the running stack.
>
> **Two, storage.** `minio-provision` takes the same keys and registers them as real MinIO users:
> `nessie-svc` on the `warehouse` bucket, `mlflow-svc` on `mlflow`. That is the second, independent
> enforcement point.
>
> **Three, credentials.** Two sidecars, `nessie-creds` and `mlflow-creds`. Each logs in with its
> own AppRole and renders only its own key into its own volume. If the read comes back empty, the
> sidecar aborts — it never writes an empty file and pretends to succeed.
>
> **Four, services.** Nessie and MLflow start only when their own key file exists. Same compose
> file, same ports, same URLs as before.
>
> Five one-shots in total, all exit zero, no new image and no new port.

*Cue:* "That is the design. Here is why you should believe it."

---

## Slide 4 — 03 · Proof: "What the refusals proved" (Udomvirak)

*On screen: 5/5 one-shots exit 0 · 2 MinIO users · 3 × 403 denied by policy · 2,500 rows unchanged; six check marks; footer "Two users, two policies, two buckets — and each service refused outside its own."*
*Time: 0:30.*

> Anyone can show a service reading its own bucket. The proof is the refusal.
>
> We ran three negative tests and got denied each time: reading **another service's** KV path,
> **writing** to our own path with a read-only policy, and listing **policies**. Three 403s. At the
> storage layer the same test gives AccessDenied on the neighbour's bucket for both users.
>
> Then the two tests that matter for everyday life. Going up a second time logs "reusing the
> existing key" — nothing rotates under a running consumer. And after `restart vault` plus a
> compose up, the keys come back **byte-identical**, because `vault-init` restores them from the
> `s3seed` volume instead of generating new ones. MLflow still writes artifacts to MinIO after
> that restart.
>
> And nothing the demo depends on moved: Spark and Dremio both still count 2,500 rows, Nessie
> `main` is unchanged, champion is still v3. Nine volumes, 3.5 GB of containers — Vault adds 0.06.

*Cue:* "It did not work on the first try. Five things broke."

---

## Slide 5 — 04 · What went wrong: "Five things that broke before it held" (Sela)

*On screen: five failure cards — KV path, dev mode, key rotation, dotted env name, Compose `$VAR` — plus the stale `.nessie.env` footnote.*
*Time: 0:45.*

> This is the honest slide, and it is the one that makes the design credible.
>
> **One.** A KV policy path is relative to its mount. We wrote `secret/data/secret/...` and the
> policy was silently wrong: the sidecar rendered an **empty** key and still exited zero. That is
> the dangerous class of bug — it looks like success. `vault_fetch.sh` now aborts on an empty read.
>
> **Two.** Dev-mode Vault is in memory. A restart wiped every key, which would have broken MinIO's
> users. `vault-init` now restores each key from `s3seed` instead of regenerating it.
>
> **Three.** The opposite risk: generating a fresh key on every `up` would rotate a running
> consumer out from under itself. So we read the existing value first.
>
> **Four.** Dash rejects exports whose name contains dots. The Nessie container takes its catalog
> secret as an environment variable instead.
>
> **Five.** Compose interpolates `$VAR` inside `command:` before the shell ever sees it. Variables
> have to be written `$$VAR`, or the command receives nothing.
>
> One leftover worth naming: there is a stale `.nessie.env` on a Desktop holding an old key. Nothing
> reads it anymore — it is a fossil of the shared-file design, and we left it alone because it sits
> outside the repo.

*Cue:* "So what changed in the talk itself?"

---

## Slide 6 — 05 · The deck: "The talk now has a security slide" (Sivchheng)

*On screen: 8 slides · 5:45 total talk time (1:15 · 1:30 · 1:45 · 1:15) · PR #4 (10 commits, 11 files, +612/−54).*
*Time: 0:30.*

> We did not shrink the old presentation to fit this in. The main deck went from seven slides to
> **eight**, and the new slide 6 is `05 · SECURITY` — "Who is allowed to read what". Three cards:
> one identity per service, read only its own secret, its own bucket and its own user, with a
> verified-live banner underneath.
>
> Everything after it moved: footers, section labels, the Q&A close, and the speaker notes on all
> eight slides. The talk is now 5:45 with the timings rebalanced — Chea Sela takes slides 5 and 6
> at 1:45, and I close on 7 and 8.
>
> The code side is **PR #4**: ten commits, eleven files, plus 612 minus 54 — compose, three setup
> scripts, the launcher, and the docs. `docker compose config` passes and the branch is mergeable
> clean.
>
> One warning for the group: **the recorded presentation predates slide 6.** Present from the
> deck, not the video, or slide 6 and the numbering will not match.

*Cue:* "And here is what we deliberately did not build."

---

## Slide 7 — 06 · Next: "What we deliberately left out" (Sivchheng)

*On screen: NOT BUILT / STILL MANUAL / NEXT IF ASKED cards; banner "Every claim on these slides came from a command we can run again."*
*Time: 0:25.*

> Three honest buckets.
>
> **Not built.** Token renewal, TTL rotation, revocation — that stays the production story. No
> dynamic secrets, no mTLS, and no orchestrator delivering the `role_id`. Vault is dev mode:
> in-memory, re-seeded on every start. That is a demo decision, not a claim about production.
>
> **Still manual.** The notebook needs one `Run All` click — auto-running it would add runs and
> could move `champion`, which is worse than a click. Tableau needs its driver copy and its Dremio
> password once. And Dremio's Nessie source still uses the MinIO **admin** pair, which is the one
> place the split does not yet reach.
>
> **Next if asked.** Scope that Dremio source to a read-only MinIO user — that is the real next
> step and it is one small change. Then delete the stale `.nessie.env`, and fold the identity
> detail into the Q&A answer rather than the main talk.

*Cue:* "Which brings us to the end."

---

## Slide 8 — 07 · Thank you (Sivchheng)

*On screen: the one-sentence answer in the navy band, the three cards (question / build / proof), repo and PR line.*
*Time: 0:15, then Q&A.*

> I will leave you with one sentence rather than a summary.
>
> **The lakehouse versions the data, MLflow records which version trained each model, and each
> service now holds only its own key.**
>
> That is the whole project in one line, and this week only added the last clause. Everything on
> these slides came from a command we can run again, on a stack that is still running — so if you
> want any number checked, ask and we will run it.
>
> Thank you. Questions?

---

## Q&A — short answers

Keep these to two sentences. If the question needs more, it is a follow-up conversation.

**"So what is service-to-service identity here?"**
Four stages: `vault-init` issues one secret, one policy and one AppRole per service; a sidecar per
service logs in and renders only its own key; MinIO enforces the same split with a bucket-scoped
user; the service starts only when its own key exists. The root token never leaves a container that
has already exited.

**"How do you know it is actually isolated?"**
Because the tests that pass are the refusals. Three 403s on KV — foreign path, write, policy list —
and AccessDenied on the neighbour's bucket for both MinIO users.

**"What happens when Vault restarts?"**
Dev-mode Vault is in memory, so `vault-init` restores each key from `s3seed` instead of generating
a new one. After `restart vault` the keys are byte-identical and MLflow still writes artifacts.

**"Isn't this just Vault for show?"**
It is dev mode, and we say so on slide 7. It is the right shape — per-service identity, read-only
policy, separate storage user — without the operational weight of an HA cluster on an 8 GB laptop.

**"Why not mTLS or dynamic secrets?"**
Days of work, another failure point, and nothing the demo can demonstrate. Those stay the
production answer: short-lived credentials, rotation, revocation, mutual TLS between services.

**"Did anything in the demo change?"**
No. 2,500 rows, same Nessie `main`, same champion v3, same dashboard. Only the credential path
moved.

**"Where is the code?"**
`github.com/ThearaGithub/mlflow-exact-stack-v2`, branch `feat/vault-service-identities`, PR #4 —
ten commits, eleven files.

**"What broke along the way?"**
A relative KV policy path that silently rendered an empty key while exiting zero. It is why the
fetch script now aborts instead of writing an empty file. The other four are on slide 5.

---

## Prep checklist

1. Stack up, all services healthy: `docker compose --profile dremio up -d`.
2. `docker compose ps` shows the five one-shots exited 0 and no restarts.
3. `SELECT COUNT(*) FROM nessie.lakehouse.churn_features` returns **2,500**.
4. MLflow has the runs and `champion` points at the expected version.
5. Open the deck on the presenting machine once — it is a theme-heavy deck and the fonts are
   Segoe UI / Consolas.
6. Say the numbers out loud once. If a figure changed since 28 November, change the slide, not the
   sentence.

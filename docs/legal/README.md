# Legal

**Date:** 2026-08-15 · **Status:** Empty. Both documents are drafted in **Phase 8**.

Nothing is written here yet, and that is on schedule — but two things are recorded now, because
they constrain earlier phases and are cheaper to know about than to discover at submission time.

## What is owed

| Document | Needed for | Phase |
|---|---|---|
| Privacy policy | **Blocks Play submission.** Must be reachable at a public URL. | 8 |
| Terms of use | Expected alongside it | 8 |
| `USE_EXACT_ALARM` justification | **Play review will ask.** Write it before submitting, not after rejection. | 8 |

Hosting: GitHub Pages under the `io.github.davamix` namespace already implied by the applicationId.
The same host serves `assetlinks.json` if Android App Links are added later.

## What the policy will have to describe

The actual data flows, which are deliberately small:

- **From Google Sign-In:** email address and display name.
- **Stored per user:** display name, IANA timezone, FCM device tokens, created/last-seen timestamps.
- **Stored per check-in:** one date, the device tap time, a server receipt time, and a timezone.
- **Stored per away period:** two dates, who set it, and their display name.
- **Stored per link:** the two user ids, a status, and the watched person's name and timezone,
  denormalized.

No location, no message content, no health data, no payments, no analytics — Google Analytics for
Firebase is deliberately **off**, as data minimisation for an app holding data about vulnerable
people.

Data is stored in `europe-west1`, chosen partly for EU residency. The owner is established in Spain.

## Two things that need a decision before drafting

**Account deletion.** Deleting a user is not one document. Their check-in history, their away
document, and the links naming them are all readable by *the other party* — so "delete my account"
has to answer what happens to data another person can currently see. GDPR requires an answer; the
design does not have one yet. Flagged in
[../security/threat-model.md](../security/threat-model.md) as T9, and owed before Phase 8.

**Who the data controller is.** An app relaying data about a third party — the watched person, who
may be less able to give informed consent than the family member who installed it — is not the
simple case. The pairing flow treats the watched person's device generating and sharing the invite
code as the consent record; whether that is sufficient is a question for a lawyer, not for this
repo.

> Anything drafted here will be **a template grounded in the real data flows, not legal advice.**
> Given vulnerable-person data and a Spanish establishment, it is worth a lawyer's eye before
> publishing.

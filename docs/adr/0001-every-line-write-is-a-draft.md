# Every ledger change made from LINE is a Draft

The Teacher chat can ask for any change the web UI can make, but the assistant never makes it directly: every change, down to a class's style, becomes a Draft that only the teacher's Confirm turns into a real record. We chose this over letting low-risk changes apply immediately, because the model will sometimes misread a name, a date or an amount, one Confirm tap is cheap, and a single rule is easier to trust than a per-action risk judgement that every new tool would have to make.

## Consequences

- Only the Teacher chat gets the full set of tools. The Group chat gets three Draft tasks: record a payment, book a single class (單堂) or trial (體驗), and a makeup request. The single-class booking replaces the original raw attendance Draft, which put a student on a roster with no purchase behind it — a free class. Letting chatter in a group the teacher doesn't control propose schedule or settings changes is a liability.
- Confirming re-checks the change against the same rules the web UI enforces, so a Draft that no longer fits (the Session was cancelled, the Credit was already used) fails with a reason instead of being applied.

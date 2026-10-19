# Group members become Students without a Confirm

When someone in the Group chat posts or joins and no Student is linked to their LINE user id, Ganesha creates a Student from their LINE display name, or links the one unlinked Student with that name, without waiting for the teacher's Confirm. It asks her only when the match is unclear, and every teacher gets an immediate notice with an undo. This is the one exception to ADR 0001. We chose it because Ganesha starts empty and the account cannot list group members, so confirming each member would put dozens of cards in front of her in the first week, while the Group chat cannot attribute payments or bookings to anyone until members are linked.

## Consequences

- Family, friends and former students in the group become Students until the teacher taps 不是學生; that answer is remembered in `line_members` so they are not created again.
- A Student created this way has no purchases or bookings; every ledger change about them still goes through a Draft and Confirm.
- Undo deletes an auto-created Student only while they have no records; after that it unlinks them and leaves the records for the teacher to fix on the web.

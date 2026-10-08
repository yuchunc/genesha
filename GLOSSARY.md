# Ganesha

The ledger for one yoga teacher's studio: her classes, her students, what they bought and paid, and the LINE assistant that helps her keep it.

## Language

### Studio

**Slot** (固定班):
A class that repeats every week at the same weekday and time, such as 週二 19:00 基礎班.
_Avoid_: class, recurring class, course

**Session** (課堂):
One dated occurrence of a class, such as 10/07（二）基礎; it is what gets cancelled, attended or missed.
_Avoid_: class, lesson

**Package** (方案):
An item on the studio's price list: 月課程 (monthly), 單堂 (drop-in) or 體驗 (trial).
_Avoid_: plan, product

**Enrollment** (報名):
A student buying Sessions of one Slot for one month on the 月課程 Package, which books them into each Session they paid for.
_Avoid_: registration, subscription

**Credit** (補課券):
One makeup entitlement a student holds, from their Package or from a cancelled Session; using it books them into another Session.
_Avoid_: makeup token, voucher

**No-show** (缺席):
A booked student who did not come to a Session.
_Avoid_: absence, skip

### LINE assistant

**Teacher chat**:
The teacher's own 1:1 LINE conversation with the assistant, and the only place she can ask for any change to the ledger.
_Avoid_: admin chat, owner chat

**Group chat**:
The teacher's LINE group with her students, which the assistant reads but never speaks in.
_Avoid_: class group, student group

**Student chat**:
A 1:1 LINE conversation between a student, or someone asking about classes, and the studio account.
_Avoid_: user chat, customer chat

**Draft**:
A change to the ledger that the assistant has proposed but the teacher has not confirmed; it has no effect until she does.
_Avoid_: proposal, suggestion, pending action

**Confirm**:
The teacher's explicit approval of a Draft, and the only way a Draft takes effect.
_Avoid_: approve, accept, apply

**Discard**:
The teacher's rejection of a Draft, after which it never takes effect.
_Avoid_: reject, cancel (a Session is cancelled; a Draft is discarded)

**Sign-up request**:
A Draft from a Student chat or the Group chat recording that someone asked to sign up for a class. 幫他報名 asks for an `enroll` Draft carrying the request, whose Confirm books the class and settles the request; 已處理 (Confirm on the request itself) only acknowledges it and books nothing.
_Avoid_: enrollment request, registration

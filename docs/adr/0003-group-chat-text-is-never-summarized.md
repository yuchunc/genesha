# Group chat text is never summarized

The Teacher chat keeps three levels of memory (recent messages, daily digests, weekly summaries), but the Group chat and Student chats get none of the summary levels. The Group chat's message text is cleared after 24 hours because it is the students' words, stored without their consent; a digest written from it would carry that text past the 24-hour limit and quietly undo the rule. Anything the ledger needs from the Group chat survives as a Draft, so nothing is lost by not summarizing it.

The 24-hour limit is enforced in prod. Dev keeps group text for development (`2026-10-05-line-group-blocklist-design.md` §5); no summary is written from it there either.

# LINE assistant tools are the teacher's tasks, not copies of the web screens

Each assistant tool is one whole task the teacher would ask for (enroll Amy in 週二晚班 for October, cancel 10/07), and code performs every step of it; the model's job is only the decisions — which student, which Slot or Session, which Package, what amount — plus asking her when it can't tell. We chose this over one tool per web-screen action because chaining lookups and writes through the model costs rounds, latency and accuracy, while the ledger's rules already live in code. For the same reason the model is handed a snapshot of the studio (Slots, Packages, upcoming Sessions, students and their nicknames) with every message instead of looking each thing up.

## Consequences

- Cards shown in LINE are a fixed set designed in code; the model picks which card to send, never its layout or its numbers. A Draft card always shows the Draft's own stored values.
- A new web feature does not automatically need a new tool; it needs one only when it is a task the teacher would ask for in chat.

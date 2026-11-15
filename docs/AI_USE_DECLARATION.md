# AI Use Declaration

**Student:** Joseph Okeoma · **Course:** MIT 8103 Advanced Database Systems · **Assessment:** First Semester CA (Practical Database Portfolio)

## 1. AI tool used
**Claude** (model: Claude Opus 5.5), developed by Anthropic, used through the Claude app.

## 2. What the AI tool was used for
* Scaffolding the repository and drafting SQL, PL/pgSQL, Python, mongosh and shell scripts for the five portfolio activities, based on the case study and design decisions I specified (POS agent banking in Lagos; PostgreSQL + MongoDB + Redis).
* Generating the synthetic, fictitious dataset (no real personal data).
* Drafting the README explanations and the 2–3 page summary document.
* Looking up current regulatory and cloud-infrastructure facts (CBN data-localisation circular, NDPA 2023, AWS Lagos Local Zone) for the cloud-deployment discussion. These sources are cited in Portfolio 5.

## 3. How the output was reviewed, tested and verified
* **Every script was executed** against real database servers (PostgreSQL 16.15, MongoDB 8.3.7, Redis 7.0.15). All figures in the documentation come from the captured outputs in the `evidence_*.txt` files and `plans/` folder, not from estimates.
* **Correctness checks are built in:** double-entry balance (0 unbalanced transactions), wallet reconciliation against the ledger (0 mismatches), constraint-violation tests, `EXCEPT` comparison of the materialized view against base tables, and before/after balances in every concurrency scenario.
* **Bugs found and corrected during testing** included: dispute statuses all generated as OPEN (ORDER BY random() reused the column), a type-cast error in the data generator, a hang in the synchronous-replication test (statement_timeout does not interrupt a SyncRep wait, so the test was redesigned to cancel the backend), and a function-signature mismatch in the deadlock test.
* **My own review:** I re-ran the Portfolio 1 and Portfolio 3 scripts on my own machine and compared the results with the saved evidence files. I read every portfolio README alongside its scripts and execution plans, and revised wording that did not match my understanding. I also studied Study Sessions 1, 2 and 4 of the MIT 8103 course notes (normalisation, ACID/CAP and distributed databases, query optimisation) so that I can explain each design decision and result myself.

I take full responsibility for the accuracy, originality and understanding of the submitted work and can explain any part of it if selected for verification.

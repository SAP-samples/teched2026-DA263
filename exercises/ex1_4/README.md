# Exercise 1.4 - Keeping Embeddings in Sync

So far you ran the `CREATE_VECTOR_EMBEDDINGS` procedure manually once. In production, new rows will be inserted and descriptions will change — the embeddings must stay in sync. There are two strategies:

- **ASYNC:** Schedule a recurring job that runs `CREATE_VECTOR_EMBEDDINGS` periodically.
  - *Pro:* Decoupled from inserts, no latency impact on writes.
  - *Con:* There is a window between insert and embedding generation where the row is not searchable.
- **SYNC:** Declare the embedding column as `GENERATED ALWAYS AS VECTOR_EMBEDDING(...)`.
  - *Pro:* Embeddings are always up-to-date immediately after an insert.
  - *Con:* Every `INSERT` blocks until the embedding model completes.
  - *Con:* Works on `NVARCHAR` columns only. For `NCLOB` columns a `TRIGGER` is required (not shown in this exercise).

This section demonstrates both approaches. Start with the async scheduler job.

## Approach 1: ASYNC — Scheduler Job

The HANA Scheduler allows you to run a stored procedure on a cron-like schedule. The job below calls `CREATE_VECTOR_EMBEDDINGS` every 10 seconds, so any newly inserted rows will have their embeddings generated within the next scheduled run.

> **Important:** Replace `'DA263_000'` with your own user schema name (e.g. `DA263_001`).

```sql
CREATE SCHEDULER JOB "SJ_RUN_CREATE_VECTOR_EMBEDDINGS" 
	CRON '* * * * * * */10' -- run every 10 seconds
	PROCEDURE SYS."CREATE_VECTOR_EMBEDDINGS" -- run this procedure
	PARAMETERS
	    SCHEMA_NAME = 'DA263_000', -- use your own schema name, e.g. DA263_001
	    TABLE_NAME = 'OBJECT_INDEX',
	    TEXT_COLUMN_NAME = 'DESCRIPTION',
	    EMBEDDING_COLUMN_NAME = 'DESCRIPTION_EMBEDDING',
	    TEXT_TYPE = 'DOCUMENT',
	    MODEL_AND_VERSION = 'SAP_GXY.20250407'
;
```

Run this query to confirm the scheduler job was created successfully.

```sql
SELECT * FROM SCHEDULER_JOBS
	WHERE SCHEMA_NAME = 'DA263_000';
```

Enable the job so it starts firing. It will run every 10 seconds.

```sql
ALTER SCHEDULER JOB "SJ_RUN_CREATE_VECTOR_EMBEDDINGS" ENABLE;
```

Insert a dummy row with no embedding to simulate a new object being added to the index.

```sql
INSERT INTO "OBJECT_INDEX"("OBJECT_OID", "DESCRIPTION")
	VALUES(1, 'dummy text');
```

Check the job execution history. Wait a few seconds and re-run this query until you see a completed execution. The `START_TIME` and `END_TIME` columns show when each run occurred.

```sql
SELECT * FROM M_SCHEDULER_JOBS
	WHERE SCHEMA_NAME = 'DA263_000' ORDER BY START_TIME DESC;
```

After a job execution completes, verify that the embedding was generated for the dummy row. The `DESCRIPTION_EMBEDDING` column should no longer be `NULL` for `OBJECT_OID` = 1.

```sql
SELECT "OBJECT_NAME", "DESCRIPTION", "DESCRIPTION_EMBEDDING"
	FROM "OBJECT_INDEX";
```

Once verified, disable the job to stop it from running.

```sql
ALTER SCHEDULER JOB "SJ_RUN_CREATE_VECTOR_EMBEDDINGS" DISABLE;
```

Then drop the job definition to clean up.

```sql
DROP SCHEDULER JOB "SJ_RUN_CREATE_VECTOR_EMBEDDINGS";
```

Remove the dummy row to restore the `OBJECT_INDEX` to its original state.

```sql
DELETE FROM "OBJECT_INDEX" WHERE "OBJECT_OID" = 1;
```

## Approach 2: SYNC — GENERATED ALWAYS AS

Drop the existing `DESCRIPTION_EMBEDDING` column so you can re-add it with the computed column definition.

```sql
ALTER TABLE "OBJECT_INDEX" DROP ("DESCRIPTION_EMBEDDING");
```

Re-add the column as `GENERATED ALWAYS AS`. HANA automatically calls `VECTOR_EMBEDDING()` on every `INSERT` or `UPDATE`. The `HIDDEN` keyword hides the column from `SELECT *` — you must name it explicitly to read it.

```sql
ALTER TABLE "OBJECT_INDEX"
	ADD ("DESCRIPTION_EMBEDDING" REAL_VECTOR(768)
		GENERATED ALWAYS AS "VECTOR_EMBEDDING"("DESCRIPTION", 'DOCUMENT', 'SAP_GXY.20250407', '{"provider_params": {"max_token_num": 2048}}') HIDDEN
		COMMENT 'The text embedding of the DESCRIPTION generated with SAP_GXY.20250407');
```

Adding the column triggers immediate embedding generation for all existing rows.

Run this query to confirm — `DESCRIPTION_EMBEDDING` should be populated for every row.

```sql
SELECT "OBJECT_NAME", "DESCRIPTION", "DESCRIPTION_EMBEDDING"
	FROM "OBJECT_INDEX";
```

Going forward, any new `INSERT` into this table will automatically get an embedding.

Continue to - [Exercise 1.5 - Cross-Encoder Reranking and the Semantic Search Function](../ex1_5/README.md)


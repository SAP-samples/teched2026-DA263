# Exercise 1.3 - Vector Embeddings and Semantic Search


Fuzzy search works well for matching object names by keywords, but it cannot understand meaning. For example, searching for `'pilots'` would not match a table described as `"Formula 1 drivers"`. Semantic search solves this by converting text to a numeric vector (embedding) that captures meaning. Texts with similar meaning produce vectors that are close together in vector space. HANA Cloud includes built-in text embedding models that generate these vectors directly inside the database.

HANA Cloud ships with two built-in text embedding models. Run the query to see them. In this exercise you will use `SAP_GXY.20250407`, which produces 768-dimensional vectors.

```sql
SELECT * FROM SYS."NLP_VECTOR_EMBEDDING_MODELS";
```

Use the `VECTOR_EMBEDDING` scalar function to generate an embedding for any text. The second argument specifies the input role: `'DOCUMENT'` for stored content, `'QUERY'` for search terms. Using the correct role improves retrieval accuracy.

```sql
SELECT "VECTOR_EMBEDDING"('This workshop is about HANA Cloud.', 'DOCUMENT', 'SAP_GXY.20250407') FROM DUMMY;
```

The result is a 768-element numeric array. The numbers themselves are not human-readable, but two vectors with similar semantic content will have a high cosine similarity score (close to 1.0).

Before persisting the embeddings, run this `SELECT` to preview what will be generated. Each row shows the `OBJECT_NAME`, its text `DESCRIPTION`, and the corresponding embedding vector. Use `'DOCUMENT'` mode here because these are stored descriptions, not search queries.

```sql
SELECT "OBJECT_NAME", "DESCRIPTION", "VECTOR_EMBEDDING"("DESCRIPTION", 'DOCUMENT', 'SAP_GXY.20250407') AS "DESCRIPTION_EMBEDDING"
	FROM "OBJECT_INDEX";
```

Rather than running individual `UPDATE`s for each row, use the built-in procedure `CREATE_VECTOR_EMBEDDINGS`. It reads all rows where the embedding column is `NULL`, generates the embeddings in batch, and writes them back. This is more efficient and ensures only missing embeddings are (re-)computed.

> **Important:** Update the `SCHEMA_NAME` parameter below to match your user schema (e.g. `DA263_001`).

```sql
CALL "CREATE_VECTOR_EMBEDDINGS"(
    SCHEMA_NAME => 'DA263_000', -- change this to refer to your own user schema name, e.g. DA263_001
    TABLE_NAME => 'OBJECT_INDEX',
    TEXT_COLUMN_NAME => 'DESCRIPTION',
    EMBEDDING_COLUMN_NAME => 'DESCRIPTION_EMBEDDING',
    TEXT_TYPE => 'DOCUMENT',
    MODEL_AND_VERSION => 'SAP_GXY.20250407'
); 
```

The procedure outputs the number of rows it processed. You should see 14 (one per object in `ERGAST_2025`). If the number is 0, the embeddings were already present — verify with the `SELECT` below.

Run this query to verify the data in `OBJECT_INDEX`. The `DESCRIPTION_EMBEDDING` column should now be populated for all rows.

```sql
SELECT "OBJECT_NAME", "DESCRIPTION", "DESCRIPTION_EMBEDDING"
	FROM "OBJECT_INDEX";
```

## Running a Semantic Search

Now run a semantic search. The query text `'f1 pilots'` is embedded on the fly using `VECTOR_EMBEDDING` with `'QUERY'` mode, then compared to each stored `DESCRIPTION_EMBEDDING` using `COSINE_SIMILARITY`. A score of `1.0` means identical direction (perfect match); `0.0` means unrelated. Rows are sorted by score descending, so the most semantically relevant objects appear first.

```sql
SELECT "COSINE_SIMILARITY"(
		"VECTOR_EMBEDDING"('f1 pilots', 'QUERY', 'SAP_GXY.20250407'), "DESCRIPTION_EMBEDDING"
		) AS "COS_SIM", "SCHEMA_NAME", "OBJECT_NAME", "DESCRIPTION"
    FROM "OBJECT_INDEX"
    ORDER BY "COS_SIM" DESC;
```

Inspect the `COS_SIM` scores. The top result should be the `DRIVERS` table, even though the query said `'pilots'` not `'drivers'`. Try changing the query string to other terms, e.g. `'race tracks'`, `'championship standings'`, `'race schedule'`. Notice how the ranking changes depending on the semantic content of the descriptions.

Continue to - [Exercise 1.4 - Keeping Embeddings in Sync](../ex1_4/README.md)


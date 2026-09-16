# Exercise 1.2 - Building the Object Index


HANA Cloud stores metadata about all database objects in system views under the `SYS` schema. The query below joins `SYS.OBJECTS` (all objects) with `SYS.TABLES` (table-specific metadata, including comments) to list all tables, views, and functions in `ERGAST_2025` along with their descriptions.

```sql
SELECT O."OBJECT_OID", O."SCHEMA_NAME", O."OBJECT_NAME", O."OBJECT_TYPE", T."COMMENTS"
	FROM SYS."OBJECTS" AS O
	LEFT JOIN SYS."TABLES" AS T ON O."OBJECT_OID" = T."TABLE_OID"
	WHERE O."SCHEMA_NAME" = 'ERGAST_2025'
		AND O."OBJECT_TYPE" IN ('TABLE', 'VIEW', 'FUNCTION')
	ORDER BY O."OBJECT_NAME" ASC;
```

You will now create a dedicated `OBJECT_INDEX` table to serve as a searchable catalog. Centralizing the metadata here allows you to add enriched descriptions, text embeddings for semantic search, and later expose the data to a property graph — all without modifying the system views directly. Note the `DESCRIPTION_EMBEDDING` column: it will store a 768-dimensional vector, generated later in this exercise. The `LC_METADATA` column is a generated column that formats key fields as JSON, required for LangChain tool compatibility.

```sql
CREATE COLUMN TABLE "OBJECT_INDEX" (
	"OBJECT_OID" BIGINT PRIMARY KEY COMMENT 'The object ID (OID) of the database object.',
	"SCHEMA_NAME" NVARCHAR(128) COMMENT 'The schema name of the database object.',
	"OBJECT_NAME" NVARCHAR(128) COMMENT 'The name of the database object.',
	"OBJECT_TYPE" NVARCHAR(128) COMMENT 'The type of the database object, e.g. TABLE, VIEW, FUNCTION.',
	"OBJECT_SUBTYPE" NVARCHAR(128) COMMENT 'The subtype of the database object, e.g. RECURSIVE for parent-child hierarchy views',
	"DESCRIPTION" NVARCHAR(5000) COMMENT 'The description of the database object.',
	"DESCRIPTION_EMBEDDING" REAL_VECTOR(768) COMMENT 'The text embedding of the DESCRIPTION generated with SAP_GXY.20250407',
	"LC_METADATA" NVARCHAR(5000) GENERATED ALWAYS AS '{"OBJECT_OID":'||"OBJECT_OID"||', "SCHEMA_NAME": "'||COALESCE("SCHEMA_NAME",'')||'", "OBJECT_NAME": "'||COALESCE("OBJECT_NAME",'')||'", "OBJECT_TYPE": "'||COALESCE("OBJECT_TYPE",'')||'"}' COMMENT 'A column to store metadata in JSON format. Required for LangChain compatibility.'
) COMMENT 'This table contains metadata about database objects, like name and description.';
```

Run the `INSERT` below to populate the `OBJECT_INDEX` with the metadata from `SYS.OBJECTS`. The `DESCRIPTION` column is populated from the `COMMENTS` defined on each table. (The `DESCRIPTION_EMBEDDING` column is left empty for now — you will fill it in a later step.)

```sql
INSERT INTO "OBJECT_INDEX"("OBJECT_OID", "SCHEMA_NAME", "OBJECT_NAME", "OBJECT_TYPE", "DESCRIPTION")
SELECT O."OBJECT_OID", O."SCHEMA_NAME", O."OBJECT_NAME", O."OBJECT_TYPE", T."COMMENTS"
	FROM SYS."OBJECTS" AS O
	LEFT JOIN SYS."TABLES" AS T ON O."OBJECT_OID" = T."TABLE_OID"
	WHERE O."SCHEMA_NAME" = 'ERGAST_2025'
		AND O."OBJECT_TYPE" IN ('TABLE', 'VIEW', 'FUNCTION');
```

Verify the inserted rows. You should see one row per table/view in `ERGAST_2025`. Notice that `DESCRIPTION_EMBEDDING` is `NULL` for now — those will be generated shortly.

```sql
SELECT * FROM "OBJECT_INDEX" ORDER BY "OBJECT_NAME";
```

## Fuzzy Text Search

Before adding vector search, let's look at HANA's built-in fuzzy text search. Fuzzy search finds approximate string matches, making it tolerant of typos and variations. The `CONTAINS` predicate below searches `OBJECT_NAME` for the term `'drives'` with a similarity threshold of `0.8`. Run it and observe which objects are returned — even though the exact table name is `DRIVERS`.

```sql
SELECT "SCHEMA_NAME", "OBJECT_NAME", SCORE()
	FROM "OBJECT_INDEX"
	WHERE CONTAINS("OBJECT_NAME", 'drives', FUZZY(0.8));
```

An alternative syntax uses the `SCORE()` function in the `SELECT` clause, which returns a relevance score for each row. This form allows sorting by relevance and works without a `WHERE` filter — all rows are scored and ranked. Compare the two result sets — both should return similar objects for the same search term.

```sql
SELECT "SCHEMA_NAME", "OBJECT_NAME", SCORE('drives' IN "OBJECT_NAME" FUZZY SEARCH MODE 'TEXT') AS "OBJECT_SCORE"
	FROM "OBJECT_INDEX"
	ORDER BY "OBJECT_SCORE" DESC;
```

Continue to - [Exercise 1.3 - Vector Embeddings and Semantic Search](../ex1_3/README.md)


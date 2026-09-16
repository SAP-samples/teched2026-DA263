# Exercise 1.5 - Cross-Encoder Reranking and the Semantic Search Function

You have now seen vector similarity search (fast, uses pre-computed embeddings). HANA Cloud also includes a **Cross-Encoder** model, which scores semantic similarity differently: it evaluates the query and each candidate text together in a single model pass, without pre-computed vectors. This is slower (it cannot be pre-computed), but typically more accurate — better at capturing relevance nuances. The typical pattern is to combine both: use vector search for fast candidate retrieval, then re-rank with a cross-encoder.

Run this query to see the available cross-encoder model(s) built into HANA Cloud.

```sql
SELECT * FROM SYS."NLP_CROSS_ENCODE_MODELS";
```

`CROSS_ENCODE` is implemented as a window function (note the `OVER ()` clause). It scores each (query, description) pair by passing both texts through the model together. Run the query and compare the ranking to the earlier vector similarity results. The cross-encoder often produces a more nuanced ranking, especially when descriptions are semantically similar.

```sql
SELECT "CROSS_ENCODE"('f1 pilots', "DESCRIPTION", 'SAP_CER.20250701') OVER () AS "CROSSENCODE_SCORE",
		"OBJECT_NAME", "DESCRIPTION"
	FROM "OBJECT_INDEX"
	ORDER BY "CROSSENCODE_SCORE" DESC;
```

## Two-Stage Retrieval: Vector Search + Cross-Encoder

In production retrieval pipelines, vector search and cross-encoder are combined in a two-stage pattern:

- **Stage 1 (RECALL):** Vector similarity retrieves the top-K candidates quickly. K is set larger than needed to ensure the truly relevant objects are included.
- **Stage 2 (PRECISION):** The cross-encoder re-ranks only those K candidates and returns the final top-N.

This gives you the speed of vector search with the accuracy of cross-encoding.

The query below implements this pattern. Examine both `VECTOR_SCORE` and `RERANK_SCORE` in the output.

```sql
WITH candidates AS (
-- Stage 1: retrieve top-K candidates by cosine similarity
    SELECT TOP 10
        "OBJECT_NAME", "DESCRIPTION",
        "COSINE_SIMILARITY"("DESCRIPTION_EMBEDDING", "VECTOR_EMBEDDING"('f1 pilots', 'QUERY', 'SAP_GXY.20250407')) AS "VECTOR_SCORE"
    FROM "OBJECT_INDEX"
    ORDER BY "VECTOR_SCORE" DESC
)
-- Stage 2: re-rank candidates with a cross-encoder
SELECT TOP 5
    "OBJECT_NAME", "DESCRIPTION",
    "CROSS_ENCODE"('f1 pilots', "DESCRIPTION", 'SAP_CER.20250701') OVER () AS "RERANK_SCORE", "VECTOR_SCORE"
FROM candidates
ORDER BY "RERANK_SCORE" DESC;
```

## The F_SEMANTIC_SEARCH Function

The two-stage search logic above is useful enough to wrap in a reusable function. `F_SEMANTIC_SEARCH` accepts a search query and optional parameters for candidate set size (`candidateK`) and the final number of results (`topN`). The defaults are 10 candidates and 3 results. Study the function body — it uses the same two-stage pattern you just ran manually.

```sql
CREATE OR REPLACE FUNCTION "F_SEMANTIC_SEARCH"(
    IN  searchQuery  NVARCHAR(1000),
    IN  candidateK   INT DEFAULT 10,
    IN  topN         INT DEFAULT 3
)
RETURNS TABLE (
    "OBJECT_OID"        BIGINT,
    "SCHEMA_NAME"      NVARCHAR(128),
    "OBJECT_NAME"      NVARCHAR(128),
    "OBJECT_TYPE"      NVARCHAR(128),
    "DESCRIPTION"		NVARCHAR(5000),
    "RERANK_SCORE"  DOUBLE
)
LANGUAGE SQLSCRIPT AS
BEGIN
    -- Stage 1: retrieve top candidate_k results by cosine similarity
    candidates = SELECT TOP :candidateK
        "OBJECT_OID", "SCHEMA_NAME", "OBJECT_NAME", "OBJECT_TYPE", "DESCRIPTION",
        COSINE_SIMILARITY(
            "DESCRIPTION_EMBEDDING",
            "VECTOR_EMBEDDING"(:searchQuery, 'QUERY', 'SAP_GXY.20250407')
        ) AS "VECTOR_SCORE"
    FROM "OBJECT_INDEX"
    ORDER BY "VECTOR_SCORE" DESC;

    -- Stage 2: re-rank candidates with a cross-encoder and return top_n
    RETURN SELECT TOP :topN
        "OBJECT_OID", "SCHEMA_NAME", "OBJECT_NAME", "OBJECT_TYPE", "DESCRIPTION",
        CROSS_ENCODE(:searchQuery, "DESCRIPTION", 'SAP_CER.20250701') OVER () AS "RERANK_SCORE"
    FROM :candidates
    ORDER BY "RERANK_SCORE" DESC;
END;
```

Call the function with a natural language query. It returns the most semantically relevant database objects. Try different queries and observe how the returned objects and `RERANK_SCORE` change.

```sql
SELECT * FROM "F_SEMANTIC_SEARCH"('f1 pilots');
```

You can override the defaults to cast a wider net before re-ranking. Increase `candidateK` when the result set is small and you suspect relevant objects are being missed.

```sql
SELECT * FROM "F_SEMANTIC_SEARCH"(searchQuery => 'f1 pilots', candidateK => 20, topN => 5);
```

Continue to - [Exercise 1.6 - LLM Integration via SAP AI Core](../ex1_6/README.md)


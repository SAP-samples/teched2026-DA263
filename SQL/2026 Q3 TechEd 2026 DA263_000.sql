-- In this exercise, you will build an "Object Index" - a searchable catalog of database objects.
-- An AI agent can query this index to discover relevant tables and views when answering a user's question in natural language.
-- The source data lives in the schema "ERGAST_2025" and contains Formula 1 race data: results, drivers, constructors, circuits, and more.

-- Run the query below to explore the RACES table and get familiar with the data.
SELECT * FROM "ERGAST_2025"."RACES" ORDER BY "date" DESC;
-- The result is sorted by date descending. The most recent race is the Abu Dhabi Grand Prix (raceId = 1144).

-- Run the next query to see the results of that race.
SELECT * FROM "ERGAST_2025"."RESULTS"
	WHERE "raceId" = 1144
	ORDER BY "position" ASC NULLS LAST;
-- The result is sorted by finishing position. The driver with driverId 846 is in position 1 -- he won the race.

-- Run the next query to look up his name.
SELECT * FROM "ERGAST_2025"."DRIVERS"
	WHERE "driverId" = 846;
-- It was Lando Norris. The DRIVERS table maps numeric driverIds to full driver names and nationalities.



/*********************************/
-- HANA Cloud stores metadata about all database objects in system views under the SYS schema.
-- The query below joins SYS.OBJECTS (all objects) with SYS.TABLES (table-specific metadata, including comments)
-- to list all tables, views, and functions in ERGAST_2025 along with their descriptions.
SELECT O."OBJECT_OID", O."SCHEMA_NAME", O."OBJECT_NAME", O."OBJECT_TYPE", T."COMMENTS"
	FROM SYS."OBJECTS" AS O
	LEFT JOIN SYS."TABLES" AS T ON O."OBJECT_OID" = T."TABLE_OID"
	WHERE O."SCHEMA_NAME" = 'ERGAST_2025'
		AND O."OBJECT_TYPE" IN ('TABLE', 'VIEW', 'FUNCTION')
	ORDER BY O."OBJECT_NAME" ASC;

-- You will now create a dedicated OBJECT_INDEX table to serve as a searchable catalog.
-- Centralizing the metadata here allows you to add enriched descriptions, text embeddings for semantic search,
-- and later expose the data to a property graph - all without modifying the system views directly.
-- Note the DESCRIPTION_EMBEDDING column: it will store a 768-dimensional vector, generated later in this exercise.
-- The LC_METADATA column is a generated column that formats key fields as JSON, required for LangChain tool compatibility.
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


-- Run the INSERT below to populate the OBJECT_INDEX with the metadata from SYS.OBJECTS.
-- The DESCRIPTION column is populated from the COMMENTS defined on each table.
-- (The DESCRIPTION_EMBEDDING column is left empty for now -- you will fill it in a later step.)
INSERT INTO "OBJECT_INDEX"("OBJECT_OID", "SCHEMA_NAME", "OBJECT_NAME", "OBJECT_TYPE", "DESCRIPTION")
SELECT O."OBJECT_OID", O."SCHEMA_NAME", O."OBJECT_NAME", O."OBJECT_TYPE", T."COMMENTS"
	FROM SYS."OBJECTS" AS O
	LEFT JOIN SYS."TABLES" AS T ON O."OBJECT_OID" = T."TABLE_OID"
	WHERE O."SCHEMA_NAME" = 'ERGAST_2025'
		AND O."OBJECT_TYPE" IN ('TABLE', 'VIEW', 'FUNCTION');

-- Verify the inserted rows. You should see one row per table/view in ERGAST_2025.
-- Notice that DESCRIPTION_EMBEDDING is NULL for now - those will be generated shortly.
SELECT * FROM "OBJECT_INDEX" ORDER BY "OBJECT_NAME";

-- Before adding vector search, let's look at HANA's built-in fuzzy text search.
-- Fuzzy search finds approximate string matches, making it tolerant of typos and variations.
-- The CONTAINS predicate below searches OBJECT_NAME for the term "drives" with a similarity threshold of 0.8.
-- Run it and observe which objects are returned - even though the exact table name is "DRIVERS".
SELECT "SCHEMA_NAME", "OBJECT_NAME", SCORE()
	FROM "OBJECT_INDEX"
	WHERE CONTAINS("OBJECT_NAME", 'drives', FUZZY(0.8));

-- An alternative syntax uses the SCORE() function in the SELECT clause, which returns a relevance score for each row.
-- This form allows sorting by relevance and works without a WHERE filter - all rows are scored and ranked.
-- Compare the two result sets - both should return similar objects for the same search term.
SELECT "SCHEMA_NAME", "OBJECT_NAME", SCORE('drives' IN "OBJECT_NAME" FUZZY SEARCH MODE 'TEXT') AS "OBJECT_SCORE"
	FROM "OBJECT_INDEX"
	ORDER BY "OBJECT_SCORE" DESC;



/*********************************/
-- Fuzzy search works well for matching object names by keywords, but it cannot understand meaning.
-- For example, searching for "pilots" would not match a table described as "Formula 1 drivers".
-- Semantic search solves this by converting text to a numeric vector (embedding) that captures meaning.
-- Texts with similar meaning produce vectors that are close together in vector space.
-- HANA Cloud includes built-in text embedding models that generate these vectors directly inside the database.

-- HANA Cloud ships with two built-in text embedding models. Run the query to see them.
-- In this exercise you will use SAP_GXY.20250407, which produces 768-dimensional vectors.
SELECT * FROM SYS."NLP_VECTOR_EMBEDDING_MODELS";

-- Use the VECTOR_EMBEDDING scalar function to generate an embedding for any text.
-- The second argument specifies the input role: 'DOCUMENT' for stored content, 'QUERY' for search terms.
-- Using the correct role improves retrieval accuracy.
SELECT "VECTOR_EMBEDDING"('This workshop is about HANA Cloud.', 'DOCUMENT', 'SAP_GXY.20250407') AS "VECTOR"
    FROM DUMMY;
-- The result is a 768-element numeric array. The numbers themselves are not human-readable,
-- but two vectors with similar semantic content will have a high cosine similarity score (close to 1.0).

-- Before persisting the embeddings, run this SELECT to preview what will be generated.
-- Each row shows the OBJECT_NAME, its text DESCRIPTION, and the corresponding embedding vector.
-- Use 'DOCUMENT' mode here because these are stored descriptions, not search queries.
SELECT "OBJECT_NAME", "DESCRIPTION", "VECTOR_EMBEDDING"("DESCRIPTION", 'DOCUMENT', 'SAP_GXY.20250407') AS "DESCRIPTION_EMBEDDING"
	FROM "OBJECT_INDEX";

-- Rather than running individual UPDATEs for each row, use the built-in procedure CREATE_VECTOR_EMBEDDINGS.
-- It reads all rows where the embedding column is NULL, generates the embeddings in batch, and writes them back.
-- This is more efficient and ensures only missing embeddings are (re-)computed.
-- Update the SCHEMA_NAME parameter below to match your user schema (e.g. DA263_001).
CALL "CREATE_VECTOR_EMBEDDINGS"(
    SCHEMA_NAME => 'DA263_000', -- change this to refer to your own user schema name, e.g. DA263_001
    TABLE_NAME => 'OBJECT_INDEX',
    TEXT_COLUMN_NAME => 'DESCRIPTION',
    EMBEDDING_COLUMN_NAME => 'DESCRIPTION_EMBEDDING',
    TEXT_TYPE => 'DOCUMENT',
    MODEL_AND_VERSION => 'SAP_GXY.20250407'
); 
-- The procedure outputs the number of rows it processed. You should see 14 (one per object in ERGAST_2025).
-- If the number is 0, the embeddings were already present -- verify with the SELECT below.

-- Run this query to verify the data in OBJECT_INDEX. The DESCRIPTION_EMBEDDING column should now be populated for all rows.
SELECT "OBJECT_NAME", "DESCRIPTION", "DESCRIPTION_EMBEDDING"
	FROM "OBJECT_INDEX";

-- Now run a semantic search. The query text "f1 pilots" is embedded on the fly using VECTOR_EMBEDDING with 'QUERY' mode,
-- then compared to each stored DESCRIPTION_EMBEDDING using COSINE_SIMILARITY.
-- A score of 1.0 means identical direction (perfect match); 0.0 means unrelated.
-- Rows are sorted by score descending, so the most semantically relevant objects appear first.
SELECT "COSINE_SIMILARITY"(
		"VECTOR_EMBEDDING"('f1 pilots', 'QUERY', 'SAP_GXY.20250407'), "DESCRIPTION_EMBEDDING"
		) AS "COS_SIM", "SCHEMA_NAME", "OBJECT_NAME", "DESCRIPTION"
    FROM "OBJECT_INDEX"
    ORDER BY "COS_SIM" DESC;
-- Inspect the COS_SIM scores. The top result should be the DRIVERS table, even though the query said "pilots" not "drivers".
-- Try changing the query string to other terms, e.g. 'race tracks', 'championship standings', 'race schedule'.
-- Notice how the ranking changes depending on the semantic content of the descriptions.



/*********************************/
-- So far you ran the CREATE_VECTOR_EMBEDDINGS procedure manually once.
-- In production, new rows will be inserted and descriptions will change - the embeddings must stay in sync.
-- There are two strategies:
--   1. ASYNC: Schedule a recurring job that runs CREATE_VECTOR_EMBEDDINGS periodically.
--             Pro: decoupled from inserts, no latency impact on writes.
--             Con: there is a window between insert and embedding generation where the row is not searchable.
--   2. SYNC:  Declare the embedding column as GENERATED ALWAYS AS VECTOR_EMBEDDING(...).
--             Pro: embeddings are always up-to-date immediately after an insert.
--             Con: every INSERT blocks until the embedding model completes.
--             Con: works on NVARCHAR columns only. For NCLOB columns a TRIGGER is required (not shown in this exercise).

-- This section demonstrates both approaches. Start with the async scheduler job.



-- APPROACH 1: ASYNC -- Scheduler Job
-- The HANA Scheduler allows you to run a stored procedure on a cron-like schedule.
-- The job below calls CREATE_VECTOR_EMBEDDINGS every 10 seconds, so any newly inserted rows
-- will have their embeddings generated within the next scheduled run.
-- IMPORTANT: Replace 'DA263_000' with your own user schema name (e.g. DA263_001) in all three places below.
CREATE SCHEDULER JOB "DA263_000"."SJ_RUN_CREATE_VECTOR_EMBEDDINGS" -- use your own schema name, e.g. DA263_001
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

-- Run this query to confirm the scheduler job was created successfully.
SELECT * FROM SCHEDULER_JOBS
	WHERE SCHEMA_NAME = 'DA263_000';

-- Enable the job so it starts firing. It will run every 10 seconds.
ALTER SCHEDULER JOB "DA263_000"."SJ_RUN_CREATE_VECTOR_EMBEDDINGS" ENABLE;

-- Insert a dummy row with no embedding to simulate a new object being added to the index.
INSERT INTO "OBJECT_INDEX"("OBJECT_OID", "DESCRIPTION")
	VALUES(1, 'dummy text');

-- Check the job execution history. Wait a few seconds and re-run this query until you see a completed execution.
-- The START_TIME and END_TIME columns show when each run occurred.
SELECT * FROM M_SCHEDULER_JOBS
	WHERE SCHEMA_NAME = 'DA263_000' ORDER BY START_TIME DESC;

-- After a job execution completes, verify that the embedding was generated for the dummy row.
-- The DESCRIPTION_EMBEDDING column should no longer be NULL for OBJECT_OID = 1.
SELECT "OBJECT_NAME", "DESCRIPTION", "DESCRIPTION_EMBEDDING"
	FROM "OBJECT_INDEX";

-- Once verified, disable the job to stop it from running.
ALTER SCHEDULER JOB "DA263_000"."SJ_RUN_CREATE_VECTOR_EMBEDDINGS" DISABLE;

-- Then drop the job definition to clean up.
DROP SCHEDULER JOB "DA263_000"."SJ_RUN_CREATE_VECTOR_EMBEDDINGS";

-- Remove the dummy row to restore the OBJECT_INDEX to its original state.
DELETE FROM "OBJECT_INDEX" WHERE "OBJECT_OID" = 1;





-- APPROACH 2: SYNC -- GENERATED ALWAYS AS
-- Drop the existing DESCRIPTION_EMBEDDING column so you can re-add it with the computed column definition.
ALTER TABLE "OBJECT_INDEX" DROP ("DESCRIPTION_EMBEDDING");

-- Re-add the column as GENERATED ALWAYS AS. HANA automatically calls VECTOR_EMBEDDING() on every INSERT or UPDATE.
-- The HIDDEN keyword hides the column from SELECT * -- you must name it explicitly to read it.
ALTER TABLE "OBJECT_INDEX"
	ADD ("DESCRIPTION_EMBEDDING" REAL_VECTOR(768)
		GENERATED ALWAYS AS "VECTOR_EMBEDDING"("DESCRIPTION", 'DOCUMENT', 'SAP_GXY.20250407', '{"provider_params": {"max_token_num": 2048}}') HIDDEN
		COMMENT 'The text embedding of the DESCRIPTION generated with SAP_GXY.20250407');
-- Adding the column triggers immediate embedding generation for all existing rows.

-- Run this query to confirm -- DESCRIPTION_EMBEDDING should be populated for every row.
SELECT "OBJECT_NAME", "DESCRIPTION", "DESCRIPTION_EMBEDDING"
	FROM "OBJECT_INDEX";
-- Going forward, any new INSERT into this table will automatically get an embedding.



/*********************************/
-- You have now seen vector similarity search (fast, uses pre-computed embeddings).
-- HANA Cloud also includes a Cross-Encoder model, which scores semantic similarity differently:
-- it evaluates the query and each candidate text together in a single model pass, without pre-computed vectors.
-- This is slower (it cannot be pre-computed), but typically more accurate -- better at capturing relevance nuances.
-- The typical pattern is to combine both: use vector search for fast candidate retrieval, then re-rank with a cross-encoder.

-- Run this query to see the available cross-encoder model(s) built into HANA Cloud.
SELECT * FROM SYS."NLP_CROSS_ENCODE_MODELS";

-- CROSS_ENCODE is implemented as a window function (note the OVER () clause).
-- It scores each (query, description) pair by passing both texts through the model together.
-- Run the query and compare the ranking to the earlier vector similarity results.
-- The cross-encoder often produces a more nuanced ranking, especially when descriptions are semantically similar.
SELECT "CROSS_ENCODE"('f1 pilots', "DESCRIPTION", 'SAP_CER.20250701') OVER () AS "CROSSENCODE_SCORE",
		"OBJECT_NAME", "DESCRIPTION"
	FROM "OBJECT_INDEX"
	ORDER BY "CROSSENCODE_SCORE" DESC;

-- In production retrieval pipelines, vector search and cross-encoder are combined in a two-stage pattern:
--   Stage 1 (RECALL):    Vector similarity retrieves the top-K candidates quickly. K is set larger than needed
--                         to ensure the truly relevant objects are included.
--   Stage 2 (PRECISION): The cross-encoder re-ranks only those K candidates and returns the final top-N.
-- This gives you the speed of vector search with the accuracy of cross-encoding.

-- The query below implements this pattern. Examine both VECTOR_SCORE and RERANK_SCORE in the output.
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

-- The two-stage search logic above is useful enough to wrap in a reusable function.
-- F_SEMANTIC_SEARCH accepts a search query and optional parameters for candidate set size (candidateK)
-- and the final number of results (topN). The defaults are 10 candidates and 3 results.
-- Study the function body - it uses the same two-stage pattern you just ran manually.
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

-- Call the function with a natural language query. It returns the most semantically relevant database objects.
-- Try different queries and observe how the returned objects and RERANK_SCORE change.
SELECT * FROM "F_SEMANTIC_SEARCH"('f1 pilots');

-- You can override the defaults to cast a wider net before re-ranking.
-- Increase candidateK when the result set is small and you suspect relevant objects are being missed.
SELECT * FROM "F_SEMANTIC_SEARCH"(searchQuery => 'f1 pilots', candidateK => 20, topN => 5);



/*********************************/
-- Next, you will create a view that enriches the raw RESULTS table with driver names, race names, and constructor names.
-- This view will serve two purposes later in the exercise:
--   1. You will use an LLM to auto-generate its description for the OBJECT_INDEX.
--   2. Its dependencies on upstream tables will be captured in the knowledge graph.
CREATE OR REPLACE VIEW "V_RESULTS" AS (
	SELECT R."raceId", R."grid", R."position", R."positionText", R."points", 
			D."forename" ||' '|| D."surname" AS "DRIVER_NAME",
			RA."name" AS "RACE_NAME", RA."date",
			C."name" AS "CONSTRUCTOR_NAME", S."status" 
		FROM "ERGAST_2025"."RESULTS" AS R
		LEFT JOIN "ERGAST_2025"."DRIVERS" AS D ON R."driverId" = D."driverId"
		LEFT JOIN "ERGAST_2025"."RACES" AS RA ON R."raceId" = RA."raceId"
		LEFT JOIN "ERGAST_2025"."CONSTRUCTORS" AS C ON R."constructorId" = C."constructorId"
		LEFT JOIN "ERGAST_2025"."STATUS" AS S ON R."statusId" = S."statusId"
);

-- Run this query to preview the view. Each row is one race result, enriched with the driver name,
-- race name, date, constructor (team) name, and finishing status (e.g. "Finished", "Retired").
SELECT * FROM "V_RESULTS" ORDER BY "raceId" DESC, "position" ASC NULLS LAST;

-- Add the V_RESULTS view to the OBJECT_INDEX so it can be discovered by search.
-- The description is intentionally left empty for now -- you will generate it with an LLM in the next step.
-- IMPORTANT: Replace 'DA263_000' with your own user schema name in the WHERE clause.
INSERT INTO "OBJECT_INDEX"("OBJECT_OID", "SCHEMA_NAME", "OBJECT_NAME", "OBJECT_TYPE", "DESCRIPTION")
SELECT O."OBJECT_OID", O."SCHEMA_NAME", O."OBJECT_NAME", O."OBJECT_TYPE", T."COMMENTS"
	FROM SYS."OBJECTS" AS O
	LEFT JOIN SYS."TABLES" AS T ON O."OBJECT_OID" = T."TABLE_OID"
	WHERE O."SCHEMA_NAME" = 'DA263_000' -- use your own user schema name here
		AND O."OBJECT_NAME" = 'V_RESULTS'
		AND O."OBJECT_TYPE" IN ('TABLE', 'VIEW', 'FUNCTION');

-- Verify that V_RESULTS was added to the OBJECT_INDEX.
-- DESCRIPTION should be NULL (to be generated by the LLM), and DESCRIPTION_EMBEDDING should also be NULL.
SELECT "SCHEMA_NAME", "OBJECT_NAME", "DESCRIPTION", "DESCRIPTION_EMBEDDING"
	FROM "OBJECT_INDEX";



/*********************************/
-- HANA Cloud can connect to external services as "Remote Sources".
-- SAP AI Core is a BTP service that provides access to Large Language Models (LLMs) from multiple providers
-- (OpenAI, Anthropic, Google, etc.) through a unified orchestration API.
-- An AI Core instance has already been connected to this HANA Cloud system as a remote source.

-- Run the query below to confirm the connection exists.
SELECT * FROM "REMOTE_SOURCES";
-- The remote source is named DA263_AICORE_ORCHESTRATION.

-- Call the system procedure below to list all LLM models available through this connection.
-- Note the model names (e.g. gpt-4.1, anthropic--claude-*) -- you will use them in subsequent queries.
CALL SYS."GET_REMOTE_SOURCE_AI_MODELS"('DA263_AICORE_ORCHESTRATION', ?);

-- The AI_TEXT_COMPLETION scalar function lets you call an LLM from inside a SQL query.
-- It takes the prompt text, the model identifier, an optional schema name, and the remote source name.
-- The result is the LLM's text response. Run the example below to verify the connection works.
SELECT "AI_TEXT_COMPLETION"(
	'What is SAP TechEd?', -- the prompt
	'"gpt-4.1"', -- the LLM to be used 
	NULL, -- the schema name or the remote source
	'DA263_AICORE_ORCHESTRATION' -- the remote source
) AS "LLM_RESPONSE" FROM DUMMY;


-- Now use AI_TEXT_COMPLETION to generate a description for V_RESULTS automatically.
-- First, confirm that DESCRIPTION is still NULL for V_RESULTS.
SELECT * 
	FROM "OBJECT_INDEX"
	WHERE "OBJECT_NAME" = 'V_RESULTS';

-- To generate a useful description, you need the view's DDL (CREATE VIEW statement).
-- A helper function F_GET_OBJECT_DEFINITION is provided in the DA263_ADMIN schema.
-- Run the query below to see the function's own source code -- a useful self-referential test.
SELECT "DA263_ADMIN"."F_GET_OBJECT_DEFINITION"(
	"SCHEMA_NAME"=>'DA263_ADMIN', 
	"OBJECT_NAME"=>'F_GET_OBJECT_DEFINITION', 
	"OBJECT_TYPE"=>'FUNCTION'
)."DEFINITION" AS "DEFINITION" FROM DUMMY;

-- Now call F_GET_OBJECT_DEFINITION for all objects in the OBJECT_INDEX.
-- Review the DEFINITION column -- this is the text you will pass to the LLM as context for generating descriptions.
SELECT "SCHEMA_NAME", "OBJECT_NAME", "OBJECT_TYPE", "DESCRIPTION", 
    "DA263_ADMIN"."F_GET_OBJECT_DEFINITION"("SCHEMA_NAME", "OBJECT_NAME", "OBJECT_TYPE")."DEFINITION" AS "DEFINITION"
	FROM "OBJECT_INDEX";

-- The anonymous block below combines everything:
--   1. It retrieves V_RESULTS' DDL using F_GET_OBJECT_DEFINITION.
--   2. It appends the DDL to a prompt that instructs the LLM to write a short description suitable for an AI agent.
--   3. It calls AI_TEXT_COMPLETION and writes the response back into OBJECT_INDEX.DESCRIPTION for V_RESULTS.
-- The embedding is regenerated automatically because of the GENERATED ALWAYS AS column definition.
-- Read the system prompt string carefully -- the phrasing guides the LLM to produce search-optimized descriptions.
DO BEGIN
	DECLARE v_prompt, v_ddl, v_response NCLOB;
	DECLARE v_llm, v_remoteSource, v_objectName NVARCHAR(128);
	
	v_prompt = 'Below is the DDL statement or column list of a SAP HANA Cloud object, i.e. table, view, or function.
		Create a short description of the object. The description helps an AI agent to find relevant objects for a data retrieval and analysis task.\n';
	v_llm = '"anthropic--claude-4.5-haiku"';
	v_remoteSource = 'DA263_AICORE_ORCHESTRATION';
	v_objectName = 'V_RESULTS';
	-- get the view's DDL
	SELECT "DA263_ADMIN"."F_GET_OBJECT_DEFINITION"("SCHEMA_NAME", "OBJECT_NAME", "OBJECT_TYPE")."DEFINITION" INTO v_ddl
		FROM "OBJECT_INDEX"
		WHERE "OBJECT_NAME" = :v_objectName;
	-- run the prompt through AI_TEXT COMPLETION and get the LLMs response
	SELECT "AI_TEXT_COMPLETION"(:v_prompt || :v_ddl, :v_llm, NULL, :v_remoteSource) INTO v_response FROM DUMMY;
	-- write the response back to the table
	UPDATE "OBJECT_INDEX" SET "DESCRIPTION" = :v_response WHERE "OBJECT_NAME" = :v_objectName;
END;

-- Run this query to read the LLM-generated description for V_RESULTS.
-- Notice that DESCRIPTION_EMBEDDING is already populated -- it was generated automatically when DESCRIPTION was updated.
SELECT "SCHEMA_NAME", "OBJECT_NAME", "OBJECT_TYPE", "DESCRIPTION", "DESCRIPTION_EMBEDDING"
	FROM "OBJECT_INDEX"
	WHERE "OBJECT_NAME" = 'V_RESULTS';

-- We can now find the view V_RESULTS using the semantic search function we built previously.
SELECT * FROM "F_SEMANTIC_SEARCH"('f1 pilots teams race results');



/*********************************/
-- AI_TEXT_COMPLETION is convenient but limited to simple prompt-response interactions.
-- For full control over the LLM call - structured output (JSON schema), multi-turn messages, model parameters -
-- use the AI_CORE_REQUEST function, which exposes the complete AI Core Orchestration API.
-- The block below sends a chat completion request with a JSON schema response format,
-- asking the LLM to generate 3 example SQL queries for the V_RESULTS view.
-- Examine the payload structure: it contains a system message, a user message with the DDL, and a strict JSON schema.
-- The response is parsed from JSON into columns using the JSON_TABLE function.

DO BEGIN
	DECLARE v_llmPayload, v_llmResponse NCLOB;
	v_llmPayload = '
{"config": {"modules": {"prompt_templating": {
	"prompt": {
        "template": [
            {
                "role": "system",
                "content": "You are a a HANA Cloud database assistant. Given the DDL below, generate 3 SQL statements that run on this object."
            },
            {
                "role": "user",
                "content": "<ddl>CREATE VIEW \"V_RESULTS\" AS (SELECT R.\"raceId\", R.\"grid\", R.\"position\", R.\"positionText\", R.\"points\", \r\n\t\t\tD.\"forename\" ||'' ''|| D.\"surname\" AS \"DRIVER_NAME\", \r\n\t\t\tRA.\"name\", RA.\"date\", \r\n\t\t\tC.\"name\" AS \"CONSTRUCTOR_NAME\", S.\"status\" \r\n\t\tFROM \"ERGAST_2025\".\"RESULTS\" AS R\r\n\t\tLEFT JOIN \"ERGAST_2025\".\"DRIVERS\" AS D ON R.\"driverId\" = D.\"driverId\"\r\n\t\tLEFT JOIN \"ERGAST_2025\".\"RACES\" AS RA ON R.\"raceId\" = RA.\"raceId\"\r\n\t\tLEFT JOIN \"ERGAST_2025\".\"CONSTRUCTORS\" AS C ON R.\"constructorId\" = C.\"constructorId\"\r\n\t\tLEFT JOIN \"ERGAST_2025\".\"STATUS\" AS S ON R.\"statusId\" = S.\"statusId\")</ddl>"
            }
        ],
        "response_format": {
            "type": "json_schema",
            "json_schema": {
                "name": "query_generation_response",
                "strict": true,
                "schema": {
                    "type": "object",
                    "properties": {
                        "sql_query": {
                            "type": "string"
                        },
                        "description": {
                            "type": "string"
                        }
                    },
                    "required": [
                        "sql_query",
                        "description"
                    ],
                    "additionalProperties": false
                }
            }
        }
    },
	"model": {"name": "anthropic--claude-3-haiku","params": {"max_tokens": 5000}}
}}}}';

	v_llmResponse = "AI_CORE_REQUEST"(NULL,'DA263_AICORE_ORCHESTRATION','v2/completion', :v_llmPayload);
	SELECT "FINISH_REASON", "ROLE", "CONTENT", "COMPLETION_TOKENS", "PROMPT_TOKENS"
		FROM JSON_TABLE(:v_llmResponse, 'strict $.final_result' COLUMNS (
		"FINISH_REASON" NVARCHAR(100) 	PATH '$.choices[0].finish_reason', 
		"ROLE" NVARCHAR(5000) 			PATH '$.choices[0].message.role', 
		"CONTENT" NVARCHAR(500000) 		PATH '$.choices[0].message.content', 
		"COMPLETION_TOKENS" INT 		PATH '$.usage.completion_tokens', 
		"PROMPT_TOKENS" INT 			PATH '$.usage.prompt_tokens')
	);
END;



/*********************************/
-- The OBJECT_INDEX lets you find relevant database objects by name or semantic search.
-- But it does not capture how objects relate to each other.
-- In this section you will build a Knowledge Graph that models:
--   - which columns belong to which tables/views (hasColumns)
--   - which tables a view depends on (hasDependency)
--   - which tables can be joined via defined associations (hasAssociation)
-- This graph can later be used by an AI agent to plan multi-table queries automatically.

-- HANA supports ASSOCIATION definitions on tables and views, which declare valid join paths between objects.
-- Associations are metadata -- they do not enforce constraints but can be used by tools and agents to plan queries.
-- Run the query below to see the existing associations in the ERGAST_2025 schema.
SELECT * FROM SYS."ASSOCIATIONS"
	ORDER BY "OBJECT_NAME";
-- Review the JOIN_CONDITION and JOIN_CARDINALITY columns.
-- For example: DRIVERS."driverId" = RESULTS."driverId" is a 1:N join -- one driver appears in many race results.

-- A second type of relationship is object dependencies: when a view or function references another object,
-- HANA records this in SYS.OBJECT_DEPENDENCIES.
-- Run the query below to see which tables V_RESULTS depends on.
-- IMPORTANT: Replace 'DA263_000' with your own user schema name.
-- The result shows the four ERGAST_2025 tables that V_RESULTS joins -- this dependency chain will be encoded in the graph.
SELECT * 
	FROM SYS."OBJECT_DEPENDENCIES" 
	WHERE "DEPENDENT_SCHEMA_NAME" = 'DA263_000'
		AND "DEPENDENT_OBJECT_NAME" = 'V_RESULTS';


-- Before building the full object graph, take a short detour to learn HANA's built-in RDF/SPARQL engine.
-- RDF (Resource Description Framework) represents data as triples: Subject → Predicate → Object.
-- For example: participant_1 → rdf:type → participant.
-- HANA Cloud provides two built-in functions for interacting with the RDF engine:
--   SPARQL_TABLE    -- runs a read-only SPARQL SELECT and returns results as a SQL table.
--   SPARQL_EXECUTE  -- runs any SPARQL statement, including INSERT DATA, to write triples.

-- Create a small dummy RDF graph to get familiar with SPARQL syntax.
-- The INSERT DATA block below adds four triples to a named graph.
-- Each triple follows the pattern: subject predicate object .
-- The PREFIX declarations define shorthand URIs to keep the statements readable.
-- IMPORTANT: Replace 'DA263_000' in the PREFIX te: declaration with your own user schema name.
CALL SYS.SPARQL_EXECUTE('
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
    PREFIX te: <http://teched2026/DA263_000/> # change this
    INSERT DATA {
    GRAPH te:dummy-graph {
        te:participant_1 rdf:type te:participant .
		te:participant_1 rdfs:label "Fred" .
		te:participant_1 te:participates_in te:DA263 .
		te:DA263 rdf:type te:workshop ;
			rdfs:label "Knowledge graph and agent memory" .
    } 
}', 
'Accept: application/sparql-results+turtle Content-Type: application/sparql-query', ?, ?);

-- Run this SPARQL query to count how many triples exist per named graph.
-- You should see one graph (te:dummy-graph) with 4 triples.
SELECT * FROM SPARQL_TABLE('
	SELECT ?graph (COUNT(*) as ?num_triples)
	WHERE {
	  GRAPH ?graph { [?p []] }
	}
	GROUP BY ?graph
');

-- Run this query to retrieve all triples. Each row is one Subject-Predicate-Object triple.
-- Compare the output to the INSERT DATA block above to understand the mapping.
SELECT * FROM SPARQL_TABLE('
	SELECT ?s ?p ?o 
	WHERE {
	  ?s ?p ?o .
	}
');

-- Run this query to fetch all properties of a specific subject (participant_1).
-- The OPTIONAL clause retrieves rdfs:label for the object if it has one - demonstrating SPARQL's optional join pattern.
SELECT * FROM SPARQL_TABLE('
	PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
	PREFIX rdf:  <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
	PREFIX te: <http://teched2026/DA263_000/>

	SELECT *
	WHERE {
	  ?participant ?p ?o .
	  OPTIONAL{?o rdfs:label ?label} .
	  FILTER(?participant = te:participant_1)
	}
');



-- Now build the real knowledge graph from your OBJECT_INDEX, columns, dependencies, and associations.
-- Rather than writing SPARQL INSERT statements manually, you will use HANA's Property Graph framework
-- as an intermediate layer. The approach is:
--   Step 1: Create relational views that expose the nodes and edges of your graph.
--   Step 2: Define a GRAPH WORKSPACE on top of those views.
--   Step 3: Use the built-in RDF_GRAPH_FROM_GRAPH_WORKSPACE procedure to convert the property graph into RDF triples.
-- This approach keeps the graph in sync with your relational data and avoids hand-coding SPARQL INSERTs.

-- Step 1a: Expose the OBJECT_INDEX as a view - each row becomes a VERTEX (node) in the property graph.
CREATE OR REPLACE VIEW "V_OBJECT_INDEX" AS (
	SELECT "OBJECT_OID", "SCHEMA_NAME", "OBJECT_NAME", "OBJECT_TYPE", "DESCRIPTION" FROM "OBJECT_INDEX"
);
SELECT * FROM "V_OBJECT_INDEX";

-- Step 1b: Expose column metadata as a second vertex type.
-- This view unions TABLE_COLUMNS and VIEW_COLUMNS so both tables and views are covered.
CREATE OR REPLACE VIEW "V_COLUMNS" AS (
	SELECT C."COLUMN_ID", C."COLUMN_NAME", C."COMMENTS", C."DATA_TYPE_NAME" FROM (
		SELECT OI."SCHEMA_NAME", OI."OBJECT_NAME", TC."COLUMN_ID", TC."COLUMN_NAME", TC."COMMENTS", TC."DATA_TYPE_NAME"
			FROM SYS."TABLE_COLUMNS" AS TC
			JOIN "OBJECT_INDEX" AS OI ON TC."SCHEMA_NAME" = OI."SCHEMA_NAME" AND TC."TABLE_NAME" = OI."OBJECT_NAME"
			WHERE OI."OBJECT_TYPE" = 'TABLE'
		UNION
		SELECT OI."SCHEMA_NAME", OI."OBJECT_NAME", VC."COLUMN_ID", VC."COLUMN_NAME", VC."COMMENTS", VC."DATA_TYPE_NAME"
			FROM SYS."VIEW_COLUMNS" AS VC 
			JOIN "OBJECT_INDEX" AS OI ON VC."SCHEMA_NAME" = OI."SCHEMA_NAME" AND VC."VIEW_NAME" = OI."OBJECT_NAME"
			WHERE OI."OBJECT_TYPE" = 'VIEW'
		) AS C
);
SELECT * FROM "V_COLUMNS";

-- Step 1c: Define the hasColumns edge -- each row connects an object node to one of its column nodes.
CREATE OR REPLACE VIEW "V_OBJECT_COLUMNS" AS (
	SELECT "TABLE_OID" AS "OBJECT_OID", "COLUMN_ID" 
		FROM SYS."TABLE_COLUMNS"
			WHERE ("SCHEMA_NAME", "TABLE_NAME") IN (SELECT "SCHEMA_NAME", "OBJECT_NAME" AS "TABLE_NAME" FROM "OBJECT_INDEX" WHERE "OBJECT_TYPE" = 'TABLE')
	UNION
	SELECT "VIEW_OID" AS "OBJECT_OID", "COLUMN_ID"
		FROM SYS."VIEW_COLUMNS" WHERE ("SCHEMA_NAME", "VIEW_NAME") IN (SELECT "SCHEMA_NAME", "OBJECT_NAME" AS "VIEW_NAME" FROM "OBJECT_INDEX" WHERE "OBJECT_TYPE" = 'VIEW')
);
SELECT * FROM "V_OBJECT_COLUMNS";

-- Step 1d: Define the hasDependency edge - each row connects a dependent object (e.g. V_RESULTS)
-- to a base object it depends on (e.g. ERGAST_2025.DRIVERS).
-- DEPENDENCY_TYPE 1 = direct reference; type 5 = transitive. The filter keeps both.
CREATE OR REPLACE VIEW "V_DEPENDENCIES" AS (
	SELECT O1."OBJECT_OID" AS "TARGET_OID", O2."OBJECT_OID" AS "SOURCE_OID", DEP."DEPENDENCY_TYPE"
	FROM SYS."OBJECT_DEPENDENCIES" AS DEP 
	JOIN "OBJECT_INDEX" AS O1 ON DEP."BASE_SCHEMA_NAME" = O1."SCHEMA_NAME"
		AND DEP."BASE_OBJECT_NAME" = O1."OBJECT_NAME"
		AND DEP."BASE_OBJECT_TYPE" = O1."OBJECT_TYPE"	
	JOIN "OBJECT_INDEX" AS O2 ON DEP."DEPENDENT_SCHEMA_NAME" = O2."SCHEMA_NAME"
		AND DEP."DEPENDENT_OBJECT_NAME" = O2."OBJECT_NAME" AND DEP."DEPENDENT_OBJECT_TYPE" = O2."OBJECT_TYPE" 
	WHERE DEP."DEPENDENCY_TYPE" IN (1, 5)
);
SELECT * FROM "V_DEPENDENCIES";

-- Step 1e: Define the hasAssociation edge, representing valid join paths between objects.
CREATE OR REPLACE VIEW "V_ASSOCIATIONS" AS (
	SELECT O1."OBJECT_OID" AS "SOURCE_OID", O2."OBJECT_OID" AS "TARGET_OID", ASS."ASSOCIATION_NAME", ASS."JOIN_CONDITION", ASS."JOIN_CARDINALITY", ASS."DEFAULT_FILTER" 
		FROM SYS."ASSOCIATIONS" AS ASS
		JOIN "OBJECT_INDEX" AS O1 ON ASS."SCHEMA_NAME" = O1."SCHEMA_NAME" AND ASS."OBJECT_NAME" = O1."OBJECT_NAME" AND O1."OBJECT_TYPE" IN ('TABLE', 'VIEW')
		JOIN "OBJECT_INDEX" AS O2 ON ASS."TARGET_SCHEMA_NAME" = O2."SCHEMA_NAME" AND ASS."TARGET_OBJECT_NAME" = O2."OBJECT_NAME" AND O2."OBJECT_TYPE" IN ('TABLE', 'VIEW')
);
SELECT * FROM "V_ASSOCIATIONS";


-- Step 2: Define the GRAPH WORKSPACE on top of those views.
CREATE OR REPLACE GRAPH WORKSPACE "OBJECT_INDEX_PROPERTY_GRAPH"
	VERTEX TABLE "V_OBJECT_INDEX" KEY COLUMN "OBJECT_OID"
	VERTEX TABLE "V_COLUMNS" KEY COLUMN "COLUMN_ID"
	EDGE TABLE "V_OBJECT_COLUMNS" SOURCE COLUMN "OBJECT_OID" REFERENCES "V_OBJECT_INDEX"
		TARGET COLUMN "COLUMN_ID" REFERENCES "V_COLUMNS" KEY COLUMN "OBJECT_OID", "COLUMN_ID"
	EDGE TABLE "V_DEPENDENCIES" SOURCE COLUMN "SOURCE_OID" REFERENCES "V_OBJECT_INDEX"
		TARGET COLUMN "TARGET_OID" REFERENCES "V_OBJECT_INDEX" KEY COLUMN "SOURCE_OID", "TARGET_OID", "DEPENDENCY_TYPE"
	EDGE TABLE "V_ASSOCIATIONS" SOURCE COLUMN "SOURCE_OID" REFERENCES "V_OBJECT_INDEX"
		TARGET COLUMN "TARGET_OID" REFERENCES "V_OBJECT_INDEX" KEY COLUMN "SOURCE_OID", "TARGET_OID";

-- Step 2: Verify the graph workspace was created successfully.
SELECT * FROM SYS."GRAPH_WORKSPACES"
	WHERE "SCHEMA_NAME" = 'DA263_000';

-- Inspect the graph schema: each row describes one property (column) of a vertex or edge entity.
-- These properties will become RDF predicates (e.g. hana:schemaName, hana:objectType) in the next step.
SELECT * FROM SYS."GRAPH_WORKSPACE_COLUMNS"
	WHERE "WORKSPACE_NAME" = 'OBJECT_INDEX_PROPERTY_GRAPH'
		AND "SCHEMA_NAME" = 'DA263_000'
	ORDER BY "ENTITY_TYPE" DESC, "ENTITY_TABLE_NAME", "ENTITY_COLUMN_NAME";

-- Step 3: Convert the property graph to RDF using RDF_GRAPH_FROM_GRAPH_WORKSPACE.
-- First, run in MAPPING_ONLY mode (dry run) to preview how each graph property maps to an RDF predicate URI.
DO BEGIN
	CALL "RDF_GRAPH_FROM_GRAPH_WORKSPACE" (
		"GRAPH_WORKSPACE_SCHEMA_NAME" => 'DA263_000', -- change to your user schema name 
		"GRAPH_WORKSPACE_NAME" => 'OBJECT_INDEX_PROPERTY_GRAPH', 
		"TARGET_GRAPH_URI" => '<DA263_000.OBJECT_INDEX_RDF_GRAPH>',
		--MAPPING_IN => "AGENT"."MAPPING_TABLE",
		"MAPPING_OUT" => o_mapping_table,
		MAPPING_MODE => 'MAPPING_ONLY'		
	);
	CREATE TABLE "PG_TO_KG_MAPPING_TABLE" AS (SELECT * FROM :o_mapping_table);
END;

-- Review the auto-generated mapping table. Each row maps one graph column to an RDF_URI (the predicate).
-- The default mapping is functional, but the next step uses a curated version with cleaner predicate names.
SELECT * 
	FROM "PG_TO_KG_MAPPING_TABLE";


-- A curated mapping table (DA263_ADMIN.PG_TO_KG_MAPPING_TABLE_09) uses cleaner, more descriptive URIs
-- such as hana:hasColumns, hana:hasDependency, hana:objectType. Run this query to inspect it.
SELECT * 
	FROM "DA263_ADMIN"."PG_TO_KG_MAPPING_TABLE_09";

-- Create a view over the curated mapping table that substitutes your user schema name.
-- IMPORTANT: Replace 'DA263_000' with your own user schema name in the SELECT clause.
CREATE OR REPLACE VIEW "V_PG_TO_KG_MAPPING_TABLE" AS (
	SELECT 'DA263_000' AS "GRAPH_WORKSPACE_SCHEMA_NAME", -- replace here
		"GRAPH_WORKSPACE_TABLE_NAME", "GRAPH_WORKSPACE_FIELD_NAME", "GRAPH_WORKSPACE_FIELD_TYPE", "RDF_PROPERTY_TYPE", "RDF_LANGUAGE_TAG", "RDF_URI"
	FROM "DA263_ADMIN"."PG_TO_KG_MAPPING_TABLE_09"
);

-- Now run the actual RDF conversion using the curated mapping.
-- MAPPING_MODE => 'STRICT' means only the mappings in the input table are applied.
-- IMPORTANT: Replace 'DA263_000' with your own user schema name in all three parameter values.
CALL SYS."RDF_GRAPH_FROM_GRAPH_WORKSPACE" (
		"GRAPH_WORKSPACE_SCHEMA_NAME" => 'DA263_000', -- replace here 
		"GRAPH_WORKSPACE_NAME" => 'OBJECT_INDEX_PROPERTY_GRAPH', 
		"TARGET_GRAPH_URI" => '<DA263_000.OBJECT_INDEX_RDF_GRAPH>', -- replace here
		"MAPPING_IN" => "V_PG_TO_KG_MAPPING_TABLE",
		"MAPPING_OUT" => ?,
		--REPLACE => TRUE,
		"MAPPING_MODE" => 'STRICT'		
	);

-- Verify the RDF graph was populated. You should see your new named graph alongside the dummy graph.
SELECT * FROM SPARQL_TABLE('
	SELECT ?graph (COUNT(*) as ?num_triples)
	WHERE {
	  GRAPH ?graph { [?p []] }
	}
	GROUP BY ?graph
');

-- Retrieve a sample of raw triples from your named graph to confirm the conversion worked.
SELECT * FROM SPARQL_TABLE('
	SELECT ?s ?p ?o 
	FROM <DA263_000.OBJECT_INDEX_RDF_GRAPH>
	WHERE {
	  ?s ?p ?o .
	}
');

-- Query for all DatabaseObject nodes and their labels.
SELECT * FROM SPARQL_TABLE('
	PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
	PREFIX rdf:  <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
	PREFIX te: <https://example.org/hana-metadata#>
	SELECT *
	FROM <DA263_000.OBJECT_INDEX_RDF_GRAPH>
	WHERE {
	  ?s rdf:type te:DatabaseObject.
		?s rdfs:label ?l .
	}
');

-- The following three SPARQL queries demonstrate the range of questions you can now answer against the graph.

-- QUERY 1 (Simple): List all database objects with their label, schema, and type.
-- Run this first to confirm that all objects from your OBJECT_INDEX are present in the graph.
SELECT * FROM SPARQL_TABLE('
    PREFIX hana: <https://example.org/hana-metadata#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    SELECT ?label ?schema ?type
    WHERE {
      ?obj a hana:DatabaseObject ;
           rdfs:label ?label ;
           hana:schemaName ?schema ;
           hana:objectType ?type .
    }
    ORDER BY ?schema ?label
');

-- QUERY 2 (Medium): For each TABLE, list its columns with data types and optional comments.
-- This demonstrates traversing the hasColumns edge between DatabaseObject and Column nodes.
SELECT * FROM SPARQL_TABLE('
    PREFIX hana: <https://example.org/hana-metadata#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    SELECT ?tableLabel ?columnLabel ?dataType ?comment
    WHERE {
      ?table a hana:DatabaseObject ;
             rdfs:label ?tableLabel ;
             hana:objectType "TABLE" ;
             hana:hasColumns ?col .
      ?col rdfs:label ?columnLabel ;
           hana:dataTypeName ?dataType .
      OPTIONAL { ?col hana:comment ?comment . }
    }
    ORDER BY ?tableLabel ?columnLabel
');

-- QUERY 3 (Complex): Transitive upstream dependency chain with column counts per upstream object.
-- Uses hana:hasDependency+ (one-or-more hops) to find all upstream objects, directly or transitively.
-- For V_RESULTS, you should see all four ERGAST_2025 tables it joins -- each with their column counts.
SELECT * FROM SPARQL_TABLE('
    PREFIX hana: <https://example.org/hana-metadata#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    SELECT ?objectLabel ?objectType
           ?upstreamLabel ?upstreamType
           (COUNT(DISTINCT ?col) AS ?upstreamColumnCount)
    WHERE {
      ?object a hana:DatabaseObject ;
              rdfs:label ?objectLabel ;
              hana:objectType ?objectType .
    
      # one-or-more hops through hasDependency
      ?object hana:hasDependency+ ?upstream .
    
      ?upstream a hana:DatabaseObject ;
                rdfs:label ?upstreamLabel ;
                hana:objectType ?upstreamType .
    
      OPTIONAL { ?upstream hana:hasColumns ?col . }
    }
    GROUP BY ?objectLabel ?objectType ?upstreamLabel ?upstreamType
    ORDER BY ?objectLabel ?upstreamLabel
');


--------------------------
-- SUMMARY: End-to-End Verification
-- Run the queries in this section to confirm that all components of the exercise are working correctly.
--------------------------

-- 1. OBJECT INDEX: All objects should be present, with non-NULL DESCRIPTION and DESCRIPTION_EMBEDDING.
SELECT
    "OBJECT_NAME",
    "OBJECT_TYPE",
    CASE WHEN "DESCRIPTION" IS NULL THEN 'MISSING' ELSE 'OK' END AS "DESCRIPTION_STATUS",
    CASE WHEN "DESCRIPTION_EMBEDDING" IS NULL THEN 'MISSING' ELSE 'OK' END AS "EMBEDDING_STATUS"
FROM "OBJECT_INDEX"
ORDER BY "OBJECT_NAME";

-- 2. SEMANTIC SEARCH: Confirm F_SEMANTIC_SEARCH returns ranked results for a sample query.
-- Expect V_RESULTS near the top for "f1 pilots teams race results".
SELECT * FROM "F_SEMANTIC_SEARCH"('f1 pilots teams race results');

-- 3. V_RESULTS VIEW: Confirm the enriched view returns rows with all aliased columns populated.
-- Expect DRIVER_NAME, RACE_NAME, CONSTRUCTOR_NAME, and status columns for the most recent race.
SELECT * FROM "V_RESULTS"
    WHERE "raceId" = (SELECT MAX("raceId") FROM "V_RESULTS")
    ORDER BY "position" ASC NULLS LAST;

-- 4. KNOWLEDGE GRAPH (RDF): Confirm the named graph exists and has triples.
-- Expect at least one row for the object index RDF graph with a triple count > 0.
SELECT * FROM SPARQL_TABLE('
    SELECT ?graph (COUNT(*) AS ?num_triples)
    WHERE { GRAPH ?graph { [?p []] } }
    GROUP BY ?graph
');

-- 5. KNOWLEDGE GRAPH (SPARQL): Confirm all DatabaseObjects are present with schema, type, and description.
-- Expect one row per object in OBJECT_INDEX.
SELECT * FROM SPARQL_TABLE('
    PREFIX hana: <https://example.org/hana-metadata#>
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    SELECT ?label ?schema ?type ?description
    FROM <DA263_000.OBJECT_INDEX_RDF_GRAPH>  # change DA263_000 to your schema name
    WHERE {
      ?obj a hana:DatabaseObject ;
           rdfs:label ?label ;
           hana:schemaName ?schema ;
           hana:objectType ?type .
      OPTIONAL { ?obj hana:description ?description . }
    }
    ORDER BY ?schema ?label
');















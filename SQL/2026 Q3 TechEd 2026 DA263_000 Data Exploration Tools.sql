-- Prerequisite: complete the Data Exploration Tools wizard (Exercise 2) using SAP HANA Cloud Central

-- Tool Pair Name: AGENT_000
-- Index Name: ERGAST

-- The Wizard creates two procedures:
-- "DATABASE_OBJECT_DISCOVERY_TOOL_AGENT_000"( query, response );
-- "DATA_RETRIEVAL_TOOL_AGENT_000"( query, response );

-- Run this procedure to identify relevant database objects for a natural language query.
CALL "DATABASE_OBJECT_DISCOVERY_TOOL_AGENT_000"( 'f1 pilots teams race results', ? );

-- Run this procedure to retrieve data and get an LLM response.
CALL "DATA_RETRIEVAL_TOOL_AGENT_000"( 'which driver won the most races? how many? list the last 3. show me the sql you used.', ? );

-- The wizard has created an object index that is used by the two procedures.
-- Just like the OBJECT_INDEX we created manually in exercise 1, the object index consists of a table with text embeddings, and an RDF graph with object relationships
SELECT * FROM "ERGAST_INDEX";

SELECT * FROM SPARQL_TABLE('
	SELECT ?graph (COUNT(*) as ?num_triples)
	WHERE {
	  GRAPH ?graph { [?p []] }
	}
	GROUP BY ?graph
');



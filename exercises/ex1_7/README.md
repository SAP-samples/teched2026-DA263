# Exercise 1.7 - Building the Knowledge Graph

The `OBJECT_INDEX` lets you find relevant database objects by name or semantic search. But it does not capture how objects relate to each other. In this section you will build a **Knowledge Graph** that models:

- Which columns belong to which tables/views (`hasColumns`)
- Which tables a view depends on (`hasDependency`)
- Which tables can be joined via defined associations (`hasAssociation`)

This graph can later be used by an AI agent to plan multi-table queries automatically.

## Exploring Object Relationships

HANA supports `ASSOCIATION` definitions on tables and views, which declare valid join paths between objects. Associations are metadata — they do not enforce constraints but can be used by tools and agents to plan queries. Run the query below to see the existing associations in the `ERGAST_2025` schema.

```sql
SELECT * FROM SYS."ASSOCIATIONS"
	ORDER BY "OBJECT_NAME";
```

Review the `JOIN_CONDITION` and `JOIN_CARDINALITY` columns. For example: `DRIVERS."driverId" = RESULTS."driverId"` is a `1:N` join — one driver appears in many race results.

A second type of relationship is object dependencies: when a view or function references another object, HANA records this in `SYS.OBJECT_DEPENDENCIES`. Run the query below to see which tables `V_RESULTS` depends on.

> **Important:** Replace `'DA263_000'` with your own user schema name.

The result shows the four `ERGAST_2025` tables that `V_RESULTS` joins — this dependency chain will be encoded in the graph.

```sql
SELECT * 
	FROM SYS."OBJECT_DEPENDENCIES" 
	WHERE "DEPENDENT_SCHEMA_NAME" = 'DA263_000' -- change this to refer to your own user schema name, e.g. DA263_001
		AND "DEPENDENT_OBJECT_NAME" = 'V_RESULTS';
```

## Introduction to RDF and SPARQL

Before building the full object graph, take a short detour to learn HANA's built-in RDF/SPARQL engine. RDF (Resource Description Framework) represents data as triples: **Subject → Predicate → Object**. For example: `participant_1 → rdf:type → participant`. HANA Cloud provides two built-in functions for interacting with the RDF engine:

- `SPARQL_TABLE` — runs a read-only SPARQL `SELECT` and returns results as a SQL table.
- `SPARQL_EXECUTE` — runs any SPARQL statement, including `INSERT DATA`, to write triples.

Create a small dummy RDF graph to get familiar with SPARQL syntax. The `INSERT DATA` block below adds four triples to a named graph. Each triple follows the pattern: `subject predicate object .` The `PREFIX` declarations define shorthand URIs to keep the statements readable.

> **Important:** Replace `'DA263_000'` in the `PREFIX te:` declaration with your own user schema name.

```sql
CALL SYS.SPARQL_EXECUTE('
    PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
    PREFIX rdf: <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
    PREFIX te: <http://teched2026/DA263_000/> # change this to refer to your own user schema name, e.g. DA263_001
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
```

Run this SPARQL query to count how many triples exist per named graph. You should see one graph (`te:dummy-graph`) with 5 triples.

```sql
SELECT * FROM SPARQL_TABLE('
	SELECT ?graph (COUNT(*) as ?num_triples)
	WHERE {
	  GRAPH ?graph { [?p []] }
	}
	GROUP BY ?graph
');
```

Run this query to retrieve all triples. Each row is one Subject-Predicate-Object triple. Compare the output to the `INSERT DATA` block above to understand the mapping.

```sql
SELECT * FROM SPARQL_TABLE('
	SELECT ?s ?p ?o 
	WHERE {
	  ?s ?p ?o .
	}
');
```

Run this query to fetch all properties of a specific subject (`participant_1`). The `OPTIONAL` clause retrieves `rdfs:label` for the object if it has one — demonstrating SPARQL's optional join pattern.

```sql
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
```

## Building the Property Graph

Now build the real knowledge graph from your `OBJECT_INDEX`, columns, dependencies, and associations. Rather than writing SPARQL `INSERT` statements manually, you will use HANA's Property Graph framework as an intermediate layer. The approach is:

1. **Step 1:** Create relational views that expose the nodes and edges of your graph.
2. **Step 2:** Define a `GRAPH WORKSPACE` on top of those views.
3. **Step 3:** Use the built-in `RDF_GRAPH_FROM_GRAPH_WORKSPACE` procedure to convert the property graph into RDF triples.

This approach keeps the graph in sync with your relational data and avoids hand-coding SPARQL INSERTs.

### Step 1a: Object Index Vertices

Expose the `OBJECT_INDEX` as a view — each row becomes a **vertex** (node) in the property graph.

```sql
CREATE OR REPLACE VIEW "V_OBJECT_INDEX" AS (
	SELECT "OBJECT_OID", "SCHEMA_NAME", "OBJECT_NAME", "OBJECT_TYPE", "DESCRIPTION" FROM "OBJECT_INDEX"
);
SELECT * FROM "V_OBJECT_INDEX";
```

### Step 1b: Column Vertices

Expose column metadata as a second vertex type. This view unions `TABLE_COLUMNS` and `VIEW_COLUMNS` so both tables and views are covered.

```sql
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
```

### Step 1c: hasColumns Edges

Define the `hasColumns` edge — each row connects an object node to one of its column nodes.

```sql
CREATE OR REPLACE VIEW "V_OBJECT_COLUMNS" AS (
	SELECT "TABLE_OID" AS "OBJECT_OID", "COLUMN_ID" 
		FROM SYS."TABLE_COLUMNS"
			WHERE ("SCHEMA_NAME", "TABLE_NAME") IN (SELECT "SCHEMA_NAME", "OBJECT_NAME" AS "TABLE_NAME" FROM "OBJECT_INDEX" WHERE "OBJECT_TYPE" = 'TABLE')
	UNION
	SELECT "VIEW_OID" AS "OBJECT_OID", "COLUMN_ID"
		FROM SYS."VIEW_COLUMNS" WHERE ("SCHEMA_NAME", "VIEW_NAME") IN (SELECT "SCHEMA_NAME", "OBJECT_NAME" AS "VIEW_NAME" FROM "OBJECT_INDEX" WHERE "OBJECT_TYPE" = 'VIEW')
);
SELECT * FROM "V_OBJECT_COLUMNS";
```

### Step 1d: hasDependency Edges

Define the `hasDependency` edge — each row connects a dependent object (e.g. `V_RESULTS`) to a base object it depends on (e.g. `ERGAST_2025.DRIVERS`). `DEPENDENCY_TYPE` 1 = direct reference; type 5 = transitive. The filter keeps both.

```sql
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
```

### Step 1e: hasAssociation Edges

Define the `hasAssociation` edge, representing valid join paths between objects.

```sql
CREATE OR REPLACE VIEW "V_ASSOCIATIONS" AS (
	SELECT O1."OBJECT_OID" AS "SOURCE_OID", O2."OBJECT_OID" AS "TARGET_OID", ASS."ASSOCIATION_NAME", ASS."JOIN_CONDITION", ASS."JOIN_CARDINALITY", ASS."DEFAULT_FILTER" 
		FROM SYS."ASSOCIATIONS" AS ASS
		JOIN "OBJECT_INDEX" AS O1 ON ASS."SCHEMA_NAME" = O1."SCHEMA_NAME" AND ASS."OBJECT_NAME" = O1."OBJECT_NAME" AND O1."OBJECT_TYPE" IN ('TABLE', 'VIEW')
		JOIN "OBJECT_INDEX" AS O2 ON ASS."TARGET_SCHEMA_NAME" = O2."SCHEMA_NAME" AND ASS."TARGET_OBJECT_NAME" = O2."OBJECT_NAME" AND O2."OBJECT_TYPE" IN ('TABLE', 'VIEW')
);
SELECT * FROM "V_ASSOCIATIONS";
```

### Step 2: Define the Graph Workspace

Define the `GRAPH WORKSPACE` on top of those views.

```sql
CREATE OR REPLACE GRAPH WORKSPACE "OBJECT_INDEX_PROPERTY_GRAPH"
	VERTEX TABLE "V_OBJECT_INDEX" KEY COLUMN "OBJECT_OID"
	VERTEX TABLE "V_COLUMNS" KEY COLUMN "COLUMN_ID"
	EDGE TABLE "V_OBJECT_COLUMNS" SOURCE COLUMN "OBJECT_OID" REFERENCES "V_OBJECT_INDEX"
		TARGET COLUMN "COLUMN_ID" REFERENCES "V_COLUMNS" KEY COLUMN "OBJECT_OID", "COLUMN_ID"
	EDGE TABLE "V_DEPENDENCIES" SOURCE COLUMN "SOURCE_OID" REFERENCES "V_OBJECT_INDEX"
		TARGET COLUMN "TARGET_OID" REFERENCES "V_OBJECT_INDEX" KEY COLUMN "SOURCE_OID", "TARGET_OID", "DEPENDENCY_TYPE"
	EDGE TABLE "V_ASSOCIATIONS" SOURCE COLUMN "SOURCE_OID" REFERENCES "V_OBJECT_INDEX"
		TARGET COLUMN "TARGET_OID" REFERENCES "V_OBJECT_INDEX" KEY COLUMN "SOURCE_OID", "TARGET_OID";
```

Verify the graph workspace was created successfully.

```sql
SELECT * FROM SYS."GRAPH_WORKSPACES"
	WHERE "SCHEMA_NAME" = 'DA263_000';
```

Inspect the graph schema: each row describes one property (column) of a vertex or edge entity. These properties will become RDF predicates (e.g. `hana:schemaName`, `hana:objectType`) in the next step.

```sql
SELECT * FROM SYS."GRAPH_WORKSPACE_COLUMNS"
	WHERE "WORKSPACE_NAME" = 'OBJECT_INDEX_PROPERTY_GRAPH'
		AND "SCHEMA_NAME" = 'DA263_000' -- change this to refer to your own user schema name, e.g. DA263_001
	ORDER BY "ENTITY_TYPE" DESC, "ENTITY_TABLE_NAME", "ENTITY_COLUMN_NAME";
```

### Step 3: Convert the Property Graph to RDF

First, run in `MAPPING_ONLY` mode (dry run) to preview how each graph property maps to an RDF predicate URI.

```sql
DO BEGIN
	CALL "RDF_GRAPH_FROM_GRAPH_WORKSPACE" (
		"GRAPH_WORKSPACE_SCHEMA_NAME" => 'DA263_000', -- change this to refer to your own user schema name, e.g. DA263_001
		"GRAPH_WORKSPACE_NAME" => 'OBJECT_INDEX_PROPERTY_GRAPH', 
		"TARGET_GRAPH_URI" => '<DA263_000.OBJECT_INDEX_RDF_GRAPH>',
		--MAPPING_IN => "AGENT"."MAPPING_TABLE",
		"MAPPING_OUT" => o_mapping_table,
		MAPPING_MODE => 'MAPPING_ONLY'		
	);
	CREATE TABLE "PG_TO_KG_MAPPING_TABLE" AS (SELECT * FROM :o_mapping_table);
END;
```

Review the auto-generated mapping table. Each row maps one graph column to an `RDF_URI` (the predicate). The default mapping is functional, but the next step uses a curated version with cleaner predicate names.

```sql
SELECT * 
	FROM "PG_TO_KG_MAPPING_TABLE";
```

A curated mapping table (`DA263_ADMIN.PG_TO_KG_MAPPING_TABLE_09`) uses cleaner, more descriptive URIs such as `hana:hasColumns`, `hana:hasDependency`, `hana:objectType`. Run this query to inspect it.

```sql
SELECT * 
	FROM "DA263_ADMIN"."PG_TO_KG_MAPPING_TABLE_09";
```

Create a view over the curated mapping table that substitutes your user schema name.

> **Important:** Replace `'DA263_000'` with your own user schema name in the `SELECT` clause.

```sql
CREATE OR REPLACE VIEW "V_PG_TO_KG_MAPPING_TABLE" AS (
	SELECT 'DA263_000' AS "GRAPH_WORKSPACE_SCHEMA_NAME", -- replace here
		"GRAPH_WORKSPACE_TABLE_NAME", "GRAPH_WORKSPACE_FIELD_NAME", "GRAPH_WORKSPACE_FIELD_TYPE", "RDF_PROPERTY_TYPE", "RDF_LANGUAGE_TAG", "RDF_URI"
	FROM "DA263_ADMIN"."PG_TO_KG_MAPPING_TABLE_09"
);
```

Now run the actual RDF conversion using the curated mapping. `MAPPING_MODE => 'STRICT'` means only the mappings in the input table are applied.

> **Important:** Replace `'DA263_000'` with your own user schema name in all three parameter values.

```sql
CALL SYS."RDF_GRAPH_FROM_GRAPH_WORKSPACE" (
		"GRAPH_WORKSPACE_SCHEMA_NAME" => 'DA263_000', -- change this to refer to your own user schema name, e.g. DA263_001
		"GRAPH_WORKSPACE_NAME" => 'OBJECT_INDEX_PROPERTY_GRAPH', 
		"TARGET_GRAPH_URI" => '<DA263_000.OBJECT_INDEX_RDF_GRAPH>', -- change this to refer to your own user schema name, e.g. DA263_001
		"MAPPING_IN" => "V_PG_TO_KG_MAPPING_TABLE",
		"MAPPING_OUT" => ?,
		--REPLACE => TRUE,
		"MAPPING_MODE" => 'STRICT'		
	);
```

Verify the RDF graph was populated. You should see your new named graph alongside the dummy graph.

```sql
SELECT * FROM SPARQL_TABLE('
	SELECT ?graph (COUNT(*) as ?num_triples)
	WHERE {
	  GRAPH ?graph { [?p []] }
	}
	GROUP BY ?graph
');
```

Retrieve a sample of raw triples from your named graph to confirm the conversion worked.

```sql
SELECT * FROM SPARQL_TABLE('
	SELECT ?s ?p ?o 
	FROM <DA263_000.OBJECT_INDEX_RDF_GRAPH> # change this to refer to your own user schema name, e.g. DA263_001
	WHERE {
	  ?s ?p ?o .
	}
');
```

Query for all `DatabaseObject` nodes and their labels.

```sql
SELECT * FROM SPARQL_TABLE('
	PREFIX rdfs: <http://www.w3.org/2000/01/rdf-schema#>
	PREFIX rdf:  <http://www.w3.org/1999/02/22-rdf-syntax-ns#>
	PREFIX te: <https://example.org/hana-metadata#>
	SELECT *
	FROM <DA263_000.OBJECT_INDEX_RDF_GRAPH> # change this to refer to your own user schema name, e.g. DA263_001
	WHERE {
	  ?s rdf:type te:DatabaseObject.
		?s rdfs:label ?l .
	}
');
```

## Querying the Knowledge Graph with SPARQL

The following three SPARQL queries demonstrate the range of questions you can now answer against the graph.

### Query 1 — Simple: List All Database Objects

List all database objects with their label, schema, and type. Run this first to confirm that all objects from your `OBJECT_INDEX` are present in the graph.

```sql
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
```

### Query 2 — Medium: Table Columns with Data Types

For each `TABLE`, list its columns with data types and optional comments. This demonstrates traversing the `hasColumns` edge between `DatabaseObject` and `Column` nodes.

```sql
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
```

### Query 3 — Complex: Transitive Upstream Dependencies

Transitive upstream dependency chain with column counts per upstream object. Uses `hana:hasDependency+` (one-or-more hops) to find all upstream objects, directly or transitively. For `V_RESULTS`, you should see all four `ERGAST_2025` tables it joins — each with their column counts.

```sql
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
```

Continue to - [Exercise 1.8 - End-to-End Verification](../ex1_8/README.md)


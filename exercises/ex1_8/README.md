# Exercise 1.8 - End-to-End Verification

Run the queries in this section to confirm that all components of the exercise are working correctly.

## 1. Object Index

All objects should be present, with non-`NULL` `DESCRIPTION` and `DESCRIPTION_EMBEDDING`.

```sql
SELECT
    "OBJECT_NAME",
    "OBJECT_TYPE",
    CASE WHEN "DESCRIPTION" IS NULL THEN 'MISSING' ELSE 'OK' END AS "DESCRIPTION_STATUS",
    CASE WHEN "DESCRIPTION_EMBEDDING" IS NULL THEN 'MISSING' ELSE 'OK' END AS "EMBEDDING_STATUS"
FROM "OBJECT_INDEX"
ORDER BY "OBJECT_NAME";
```

## 2. Semantic Search

Confirm `F_SEMANTIC_SEARCH` returns ranked results for a sample query. Expect `V_RESULTS` near the top for `'f1 pilots teams race results'`.

```sql
SELECT * FROM "F_SEMANTIC_SEARCH"('f1 pilots teams race results');
```

## 3. V_RESULTS View

Confirm the enriched view returns rows with all aliased columns populated. Expect `DRIVER_NAME`, `RACE_NAME`, `CONSTRUCTOR_NAME`, and status columns for the most recent race.

```sql
SELECT * FROM "V_RESULTS"
    WHERE "raceId" = (SELECT MAX("raceId") FROM "V_RESULTS")
    ORDER BY "position" ASC NULLS LAST;
```

## 4. Knowledge Graph (RDF)

Confirm the named graph exists and has triples. Expect at least one row for the object index RDF graph with a triple count > 0.

```sql
SELECT * FROM SPARQL_TABLE('
    SELECT ?graph (COUNT(*) AS ?num_triples)
    WHERE { GRAPH ?graph { [?p []] } }
    GROUP BY ?graph
');
```

## 5. Knowledge Graph (SPARQL)

Confirm all `DatabaseObject`s are present with schema, type, and description. Expect one row per object in `OBJECT_INDEX`.

> **Note:** Replace `DA263_000` in the `FROM` clause with your own schema name.

```sql
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
```

Continue to - [Exercise 2 - Data Exploration Tools](../ex2/README.md)


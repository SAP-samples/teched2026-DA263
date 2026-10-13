# Exercise 1.1 - Exploring the Formula 1 Dataset

In this exercise, you will build an **Object Index** — a searchable catalog of database objects. An AI agent can query this index to discover relevant tables and views when answering a user's question in natural language. The source data lives in the schema `ERGAST_2025` and contains Formula 1 race data: results, drivers, constructors, circuits, and more.

Run the query below to explore the `RACES` table and get familiar with the data.

```sql
SELECT * FROM "ERGAST_2025"."RACES" ORDER BY "date" DESC;
```

The result is sorted by date descending. The most recent race is the Abu Dhabi Grand Prix (`raceId` = 1144).

Run the next query to see the results of that race.

```sql
SELECT * FROM "ERGAST_2025"."RESULTS"
	WHERE "raceId" = 1144
	ORDER BY "position" ASC NULLS LAST;
```

The result is sorted by finishing position. The driver with `driverId` 846 is in position 1 — they won the race.

Run the next query to look up their name.

```sql
SELECT * FROM "ERGAST_2025"."DRIVERS"
	WHERE "driverId" = 846;
```

It was Lando Norris. The `DRIVERS` table maps numeric `driverId`s to full driver names and nationalities.

Continue to - [Exercise 1.2 - Building the Object Index](../ex1_2/README.md)


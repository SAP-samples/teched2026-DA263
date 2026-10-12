# Exercise 2 - Data Exploration Tools

In this exercise, we will use the `Data Exploration Tools` and complete a wizard which creates an object index similar to what we created manually in exercise 1. This object index is used by two generated database procedures:
- "DATABASE_OBJECT_DISCOVERY_TOOL"( query, response );
- "DATA_RETRIEVAL_TOOL"( query, response );

`DATABASE_OBJECT_DISCOVERY_TOOL` takes a natural language query and returns relevant database objects, including their descriptions and definitions.
`DATA_RETRIEVAL_TOOL` takes a natural language query, generates SQL statements, and returns a response grounded in the retrieved data.


## Open the Data Exploration Tools

Choose **Instances** on the left panel in SAP HANA Cloud Central, open the context menu (Click on the 3 dots ... under `Actions`) for your SAP HANA Cloud instance, and click on `Manage Data Exploration Tools`.

![](../ex2/images/SNAG-0007.png)

**If required**, enter your database credentials. Otherwise, just proceed.
<br>**Username** `DA263_000` (replace 000 with your student number, e.g. 001)
<br>**Password** `welCome!26`

![](../ex2/images/SNAG-0008.png)

Click on `Create` to define a new tool pair.

![](../ex2/images/SNAG-0010.png)

We will now create Data Exploration Tools using a wizard
- For `Remote Sources`, choose `Select from existing remote sources`.
- Select the remote source `DA263_AICORE_ORCHESTRATION` from the pick-list.
- Enter `AGENT_000` (replace 000 with your student number, e.g. 001) as Tool Pair Name.
- Make sure the suggested schema matches your user schema, e.g. `DA263_001`.
- Enter `ERGAST` as Index.

![](../ex2/images/SNAG-0011.png)

**Add** the database objects which should be exposed via the Data Exploration Tools.

![](../ex2/images/SNAG-0012.png)

Select all the tables in the `ERGAST_2025` schema and confirm the pop-up with **Add**.

![](../ex2/images/SNAG-0013.png)

Finally, click **Create** and wait for the creation process to finish.

![](../ex2/images/SNAG-0014.png)

Click **Refresh** in the upper right to update the status.

![](../ex2/images/SNAG-0016.png)

Once the Tool Pair is `Ready`, click on **Open in SQL Console**.

![](../ex2/images/SNAG-0016a.png)

This brings up two examples on how to use the Data Exploration Tools via generated database procedures. You can now enter your natural language query and run the procedures
- e.g. 'which driver won the most races?'

**OR**

open the short SQL script [2026 Q3 TechEd 2026 DA263_000 Data Exploration Tools.sql](/SQL/2026%20Q3%20TechEd%202026%20DA263_000%20Data%20Exploration%20Tools.sql).

![](../ex2/images/SNAG-0017.png)

## Summary

We have used the Data Exploration Tools in SAP HANA Cloud Central to create an index of database objects. The wizard also generates two database procedures
- "DATABASE_OBJECT_DISCOVERY_TOOL"( query, response );
- "DATA_RETRIEVAL_TOOL"( query, response );

`DATABASE_OBJECT_DISCOVERY_TOOL` takes a natural language query and returns relevant database objects, including their descriptions and definitions.
`DATA_RETRIEVAL_TOOL` takes a natural language query, generates SQL statements, and returns a response grounded in the retrieved data.


Continue to - [Exercise 3 - Using SAP HANA Cloud via LangChain ](../ex3/README.md)

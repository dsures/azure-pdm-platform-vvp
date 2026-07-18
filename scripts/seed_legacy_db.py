import os
import pandas as pd
from dotenv import load_dotenv
from sqlalchemy import create_engine, text

load_dotenv()

sa_password = os.environ["MSSQL_SA_PASSWORD"]

conn_str = (
    f"mssql+pyodbc://sa:{sa_password}@localhost:1433/PdMLegacy"
    "?driver=ODBC+Driver+18+for+SQL+Server&TrustServerCertificate=yes"
)
engine = create_engine(conn_str)

# Clear existing rows first so this script can be re-run safely
with engine.begin() as conn:
    conn.execute(text("TRUNCATE TABLE MaintenanceHistory"))
    conn.execute(text("TRUNCATE TABLE Machines"))

machines = pd.read_csv("data/raw/PdM_machines.csv")
maint = pd.read_csv("data/raw/PdM_maint.csv")

machines.to_sql("Machines", engine, if_exists="append", index=False)
maint.to_sql("MaintenanceHistory", engine, if_exists="append", index=False)

print(f"Loaded {len(machines)} machines, {len(maint)} maintenance records.")
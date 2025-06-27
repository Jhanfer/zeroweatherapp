import pandas as pd
import os 
try:
    df = pd.read_csv("lib/airports.csv", keep_default_na=False)
    

    df["continent"] = df["continent"].astype(str).str.strip().str.upper()
    df["type"] = df["type"].astype(str).str.strip().str.lower()

    filtered = df[
        (df["continent"].isin(["EU","NA","SA"])) &
        (df["type"].isin(["small_airport","medium_airport", "large_airport"])) &
        (df["ident"].notna()) &
        (df["ident"].str.match(r'^[A-Z]{4}$'))
    ][["ident", "latitude_deg", "longitude_deg", "name", "continent","iso_country"]]
    filtered.to_csv("lib/stations.csv", index=False)
    print(df["continent"].head())
except FileNotFoundError:
    print("Archivo no encontrado.")
    print(os.getcwd())

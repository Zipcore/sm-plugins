/**
 * Sourcemod Plugin Template
 */

#pragma semicolon 1

#include <sourcemod>
#undef REQUIRE_PLUGIN                       // Support late loads.
#include <roundendsongs>

#define PLUGIN_VERSION          "0.3.3"     // Plugin version.

public Plugin:myinfo = {
    name = "Round End Music (SQLite)",
    author = "nosoop",
    description = "Extension of the Round End Music plugin to support SQLite databases.",
    version = PLUGIN_VERSION,
    url = "http://github.com/nosoop"
}

#define SQL_QUERY_LENGTH        1024

new Handle:g_hCDatabaseName = INVALID_HANDLE,           String:g_sDatabaseName[32],
    Handle:g_hCTableName = INVALID_HANDLE,              String:g_sTableName[32],
    Handle:g_hCSongDir = INVALID_HANDLE,                String:g_sSongDir[32];

// SQLite snippet to generate a number between 0 to 1 for each query.
// Source:  http://stackoverflow.com/a/23785593
new String:g_sRandomFunction[] = "random() / 18446744073709551616 + 0.5";

public OnPluginStart() {

    g_hCDatabaseName = CreateConVar("sm_rem_sqli_db", "roundendsongs", "Database entry in databases.cfg to load songs from.", FCVAR_PLUGIN|FCVAR_SPONLY);
    PrepareStringConVar(g_hCDatabaseName, g_sDatabaseName, sizeof(g_sDatabaseName));
    
    g_hCTableName = CreateConVar("sm_rem_sqli_tbl", "songdata", "Table to read songs from.", FCVAR_PLUGIN|FCVAR_SPONLY);
    PrepareStringConVar(g_hCTableName, g_sTableName, sizeof(g_sTableName));
    
    g_hCSongDir = CreateConVar("sm_rem_sqli_dir", "roundendsongs/", "Directory that the songs are located in, if not already defined as the full path in the database.", FCVAR_PLUGIN|FCVAR_SPONLY);
    PrepareStringConVar(g_hCSongDir, g_sSongDir, sizeof(g_sSongDir));
    
    // Execute configuration.
    AutoExecConfig(true, "plugin.rem_sqlite");
}

/**
 * Get a String value from a ConVar, store into a String and hook changes.  Pretty self-explanatory.
 */
PrepareStringConVar(Handle:hConVar, String:sValue[], nValueSize) {
    GetConVarString(hConVar, sValue, nValueSize);
    HookConVarChange(hConVar, OnConVarChanged);
}

public Action:REM_OnSongsRequested(nSongs) {
    new nSongsAdded;
    new songIds[nSongs];

    new Handle:hDatabase = GetSongDatabaseHandle();
    
    // Create sorter function.
    decl String:sWeightFunction[SQL_QUERY_LENGTH];
    Format(sWeightFunction, sizeof(sWeightFunction),
            "((playcount + %d) * (%s))", RoundFloat(GetHighestPlayCount(hDatabase) * 0.25), g_sRandomFunction);
    
    decl String:sSongQuery[SQL_QUERY_LENGTH];
    Format(sSongQuery, sizeof(sSongQuery),
            "SELECT artist,track,filepath,file_id FROM `%s` WHERE enabled = 1 ORDER BY %s LIMIT %d",
            g_sTableName, sWeightFunction, nSongs);
    
    new Handle:hSongQuery = SQL_Query(hDatabase, sSongQuery);
    
    decl String:rgsSongData[3][PLATFORM_MAX_PATH], songId;
    while (SQL_FetchRow(hSongQuery)) {
        // Fetch song data.
        for (new i = 0; i < 3; i++) {
            SQL_FetchString(hSongQuery, i, rgsSongData[i], sizeof(rgsSongData[]));
        }
        
        songId = SQL_FetchInt(hSongQuery, 3);
        
        // Append directory.
        Format(rgsSongData[ARRAY_FILEPATH], sizeof(rgsSongData[]), "%s%s", g_sSongDir, rgsSongData[ARRAY_FILEPATH]);
        if (REM_AddToQueue(rgsSongData[ARRAY_ARTIST], rgsSongData[ARRAY_TITLE], rgsSongData[ARRAY_FILEPATH])) {
            songIds[nSongsAdded++] = songId;
        }
    }
    CloseHandle(hSongQuery);
    
    // Increment playcounts for added songs.
    for (new i = 0; i < nSongsAdded; i++) {
        decl String:sUpdateQuery[SQL_QUERY_LENGTH];
        Format(sUpdateQuery, sizeof(sUpdateQuery),
                "UPDATE `%s` SET playcount=playcount+1 WHERE file_id = %d",
                g_sTableName, songIds[i]);
        SQL_FastQuery(hDatabase, sUpdateQuery);
    }
    
    CloseHandle(hDatabase);
}

GetHighestPlayCount(Handle:hDatabase) {
    decl String:sPlayCountQuery[SQL_QUERY_LENGTH];
    Format(sPlayCountQuery, sizeof(sPlayCountQuery),
            "SELECT MAX(playcount) FROM `%s` WHERE enabled=1",
            g_sTableName);
    
    new Handle:hPlayCountQuery = SQL_Query(hDatabase, sPlayCountQuery);
    SQL_FetchRow(hPlayCountQuery);
    
    new nTopPlays = SQL_FetchInt(hPlayCountQuery, 0);
    
    CloseHandle(hPlayCountQuery);
    
    return nTopPlays;
}

/**
 * Gets a handle on the SQLite database.
 */
Handle:GetSongDatabaseHandle() {
    new Handle:hDatabase = INVALID_HANDLE;
    
    if (SQL_CheckConfig(g_sDatabaseName)) {
        decl String:sErrorBuffer[256];
        if ( (hDatabase = SQL_Connect(g_sDatabaseName, true, sErrorBuffer, sizeof(sErrorBuffer))) == INVALID_HANDLE ) {
            SetFailState("[rem-sqlite] Could not connect to Round End Songs database: %s", sErrorBuffer);
        } else {
            return hDatabase;
        }
    } else {
        SetFailState("[rem-sqlite] Could not find configuration %s for the Round End Songs database.", g_sDatabaseName);
    }
    return INVALID_HANDLE;
}

/**
 */
public OnConVarChanged(Handle:hConVar, const String:sOldValue[], const String:sNewValue[]) {
    if (hConVar == g_hCDatabaseName) {
        strcopy(g_sDatabaseName, sizeof(g_sDatabaseName), sNewValue);
    } else if (hConVar == g_hCTableName) {
        if (IsCleanTableValue(sNewValue)) {
            strcopy(g_sTableName, sizeof(g_sTableName), sNewValue);
        } else {
            LogError("Table changed to use unsanitary table value %s -- attempting to revert.", sNewValue);
            if (IsCleanTableValue(sOldValue)) {
                SetConVarString(g_hCTableName, sOldValue);
            } else {
                SetFailState("Previous table value %s is also dirty.  Pausing.");
            }
        }
    } else if (hConVar == g_hCSongDir) {
        strcopy(g_sSongDir, sizeof(g_sSongDir), sNewValue);
    }
}

bool:IsCleanTableValue(const String:sTable[]) {
    return (StrContains(sTable, "`") == -1);
}
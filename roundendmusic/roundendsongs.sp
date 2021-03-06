/**
 * Sourcemod Plugin Template
 */

#pragma semicolon 1

#include <sourcemod>
#include <sdktools>
#include <clientprefs>

#define PLUGIN_VERSION          "1.6.1"     // Plugin version.

#define ARRAY_ARTIST            0
#define ARRAY_TITLE             1
#define ARRAY_FILEPATH          2

#define STR_ARTIST_LENGTH       48          // Maximum length of an artist name.
#define STR_TITLE_LENGTH        48          // Maximum length of a song title.

#define CELL_PLAYCOUNT          1

public Plugin:myinfo = {
    name = "Round End Music",
    author = "nosoop",
    description = "A plugin to queue up a number of songs to play during the end round.",
    version = PLUGIN_VERSION,
    url = "http://github.com/nosoop"
}

new g_iTrack, g_nSongsAdded;

// Contains title, artist / source, and file path, respectively.
new Handle:g_hSongData[3] = { INVALID_HANDLE, INVALID_HANDLE, INVALID_HANDLE };

// Contains pointer to a shuffled track and a boolean to determine if the track was played this map.
new Handle:g_hTrackNum = INVALID_HANDLE;

new Handle:g_hCPluginEnabled = INVALID_HANDLE,  bool:g_bPluginEnabled = true,   // Determines whether or not the plugin is enabled.
    Handle:g_hCMaxSongCount = INVALID_HANDLE,   g_nMaxSongsLoaded,              // Determines the maximum number of songs to request.
    Handle:g_hCSongPlayDelay = INVALID_HANDLE,  Float:g_fSongPlayDelay;         // Determines how long to wait until the endround song begins to play.

// Client preferences on volume.  TODO Properly handle nonexistent clientprefs.
new Handle:g_hVolumeCookie = INVALID_HANDLE,    Float:g_rgfClientVolume[MAXPLAYERS+1];

new Handle:g_hFRequestSongs = INVALID_HANDLE,   // Global forward to notify that songs are needed.
    Handle:g_hFSongPlayed = INVALID_HANDLE;     // Global forward to notify that a song was played.

public OnPluginStart() {
    // Initialize cvars and arrays.
    g_hCPluginEnabled = CreateConVar("sm_rem_enabled", "1", "Enables Round End Music.", FCVAR_PLUGIN|FCVAR_SPONLY, true, 0.0, true, 1.0);
    g_hCMaxSongCount = CreateConVar("sm_rem_maxsongs", "3", "Maximum number of songs to download from a single map.", FCVAR_PLUGIN|FCVAR_SPONLY, true, 1.0);
    
    
    g_hCSongPlayDelay = CreateConVar("sm_rem_songdelay", "4.3", "Amount of time to wait after round end to start playing the song.", FCVAR_PLUGIN|FCVAR_SPONLY, true, 0.0);
    g_fSongPlayDelay = GetConVarFloat(g_hCSongPlayDelay);
    HookConVarChange(g_hCSongPlayDelay, OnConVarChanged);
    
    // -- Reshuffle queued tracks (boolean)
    
    // Register commands.
    RegAdminCmd("sm_playsong", Command_PlaySong, ADMFLAG_ROOT, "Play a round-end song (for debugging).");
    RegAdminCmd("sm_rem_rerollsongs", Command_RerollSongs, ADMFLAG_ROOT, "Redo round end music (for debugging).");
    
    RegConsoleCmd("sm_songlist", Command_DisplaySongList, "Opens a menu with the current song listing.");
    RegConsoleCmd("sm_songvolume", Command_SetSongVolume, "Sets the client's volume level for music at round-end.");
    
    // Initialize the arrays.
    g_hSongData[ARRAY_ARTIST] = CreateArray(STR_ARTIST_LENGTH);
    g_hSongData[ARRAY_TITLE] = CreateArray(STR_TITLE_LENGTH);
    g_hSongData[ARRAY_FILEPATH] = CreateArray(PLATFORM_MAX_PATH);
    
    g_hTrackNum = CreateArray(2);
    
    // Hook endround.
    HookEvent("teamplay_round_win", Event_RoundEnd);
    
    g_hVolumeCookie = RegClientCookie("RoundEndSongVolume", "Volume of songs played through the Round End Music plugin.", CookieAccess_Protected);
    for (new i = MaxClients; i > 0; --i) {
        if (!AreClientCookiesCached(i)) {
            g_rgfClientVolume[i] = 1.0;
            continue;
        }
        OnClientCookiesCached(i);
    }
    SetCookieMenuItem(CookieMenu_RoundEndSongVolume, INVALID_HANDLE, "Round End Music Volume");
    
    // Init global forwards.
    g_hFRequestSongs = CreateGlobalForward("REM_OnSongsRequested", ET_Hook, Param_Cell);
    g_hFSongPlayed = CreateGlobalForward("REM_OnSongPlayed", ET_Ignore, Param_String);
    
    AutoExecConfig(true, "plugin.rem_core");
}

public APLRes:AskPluginLoad2(Handle:hMySelf, bool:bLate, String:strError[], iMaxErrors) {
    RegPluginLibrary("nosoop-roundendmusic");
    CreateNative("REM_AddToQueue", Native_AddToQueue);
    return APLRes_Success;
}

public OnClientCookiesCached(client) {
    decl String:sValue[8];
    GetClientCookie(client, g_hVolumeCookie, sValue, sizeof(sValue));
    
    g_rgfClientVolume[client] = sValue[0] == '\0' ? 1.0 : StringToFloat(sValue);
}  

public OnConfigsExecuted() {
    // Only determine if we want to load things on map change.
    g_bPluginEnabled = GetConVarBool(g_hCPluginEnabled);
    g_nMaxSongsLoaded = GetConVarInt(g_hCMaxSongCount);

    QueueSongs();
}

public Event_RoundEnd(Handle:event, const String:name[], bool:dontBroadcast) {
    if (GetListeningPlayerCount() > 0) {
        CreateTimer(g_fSongPlayDelay, Timer_PlayEndRound, _, TIMER_FLAG_NO_MAPCHANGE);
    } else {
        PrintToServer("[rem] No players available to play endround music to.  Skipping...");
    }
}

public Action:Timer_PlayEndRound(Handle:timer, any:data) {
    PlayEndRoundSong(GetNextSong());
    return Plugin_Handled;
}

PlayEndRoundSong(iSong) {
    if (!g_bPluginEnabled) {
        return;
    }

    decl String:sSongArtist[STR_ARTIST_LENGTH],
        String:sSongTitle[STR_TITLE_LENGTH],
        String:sSoundPath[PLATFORM_MAX_PATH];
    GetArrayString(g_hSongData[ARRAY_ARTIST], iSong, sSongArtist, sizeof(sSongArtist));
    GetArrayString(g_hSongData[ARRAY_TITLE], iSong, sSongTitle, sizeof(sSongTitle));
    GetArrayString(g_hSongData[ARRAY_FILEPATH], iSong, sSoundPath, sizeof(sSoundPath));
    
    // Increase playcount.
    SetArrayCell(g_hTrackNum, iSong, GetArrayCell(g_hTrackNum, iSong, CELL_PLAYCOUNT) + 1, CELL_PLAYCOUNT);
    
    for (new i = MaxClients; i > 0; --i) {
        if (IsClientInGame(i) && g_rgfClientVolume[i] > 0.0) {
            EmitSoundToClient(i, sSoundPath, _, _, _, _, g_rgfClientVolume[i]);
            PrintToChat(i, "\x01You are listening to \x04%s\x01 from \x04%s\x01!", sSongTitle, sSongArtist);
        }
    }
    
    // Show song information in chat.
    // TODO Nice coloring?
    PrintToServer("[rem] Played song %d of %d (%s)", iSong + 1, GetActiveSongCount(), sSoundPath);
    
    Call_StartForward(g_hFSongPlayed);
    Call_PushString(sSoundPath);
    Call_Finish();
}

QueueSongs() {
    if (!g_bPluginEnabled) {
        return;
    }

    // Account for possible change in max download amount by keeping track of each separately here.
    new iSongCheck, nSongsLastActive = GetArraySize(g_hTrackNum);
    while (nSongsLastActive > iSongCheck) {
        if (GetArrayCell(g_hTrackNum, iSongCheck, CELL_PLAYCOUNT) > 0) {
            for (new i = 0; i < 3; i++) {
                RemoveFromArray(g_hSongData[i], iSongCheck);
            }
            RemoveFromArray(g_hTrackNum, iSongCheck);
            
            g_nSongsAdded--;
            nSongsLastActive--;
        } else {
            iSongCheck++;
        }
    }

    if (g_nSongsAdded < g_nMaxSongsLoaded) {
        // Request songs.
        new Action:result;
        Call_StartForward(g_hFRequestSongs);
        Call_PushCell(g_nMaxSongsLoaded);
        Call_Finish(result);
    }
    
    // Initialize shuffler.
    ClearArray(g_hTrackNum);
    
    decl String:sSongPath[PLATFORM_MAX_PATH], String:sFilePath[PLATFORM_MAX_PATH];
    for (new i = 0; i < GetActiveSongCount(); i++) {
        GetArrayString(g_hSongData[ARRAY_FILEPATH], i, sSongPath, sizeof(sSongPath));
        PrecacheSound(sSongPath, true);
        
        Format(sFilePath, sizeof(sFilePath), "sound/%s", sSongPath);
        AddFileToDownloadsTable(sFilePath);
        
        new track = PushArrayCell(g_hTrackNum, i);
        SetArrayCell(g_hTrackNum, track, 0, CELL_PLAYCOUNT);
        
        PrintToServer("[rem] Added song %d: %s", i, sSongPath);
    }
    
    // Shuffle pointers with Fisher-Yates.  Source because I don't know it off the top of my head:
    // http://spin.atomicobject.com/2014/08/11/fisher-yates-shuffle-randomization-algorithm/
    new nTracks = GetActiveSongCount();
    for (new i = 0; i < nTracks; i++) {
        new j = GetRandomInt(i, nTracks - 1);
        SwapArrayItems(g_hTrackNum, i, j);
    }
}

/**
 * GetActiveSongCount returns the lower of g_nSongsAdded and g_nMaxSongsLoaded.
 * This matters in the event that g_nMaxSongsLoaded is changed to be smaller than g_nSongsAdded,
 * in which case the song plugin should limit the songs to the max song count.
 */
GetActiveSongCount() {
    return g_nSongsAdded < g_nMaxSongsLoaded ? g_nSongsAdded : g_nMaxSongsLoaded;
}

GetNextSong() {
    new iTrack = GetArrayCell(g_hTrackNum, g_iTrack);
    g_iTrack = (g_iTrack + 1) % GetActiveSongCount();
    return iTrack;
}

/**
 * Adds a song to the queue.  Returns true if the song was added, false otherwise.
 */
bool:AddToQueue(const String:sArtist[], const String:sTrack[], const String:sFilePath[]) {
    // Limit songs added to max song count and automatically discard duplicates.
    if (FindStringInArray(g_hSongData[ARRAY_FILEPATH], sFilePath) == -1 && g_nSongsAdded < g_nMaxSongsLoaded) {
        PushArrayString(g_hSongData[ARRAY_ARTIST], sArtist);
        PushArrayString(g_hSongData[ARRAY_TITLE], sTrack);
        PushArrayString(g_hSongData[ARRAY_FILEPATH], sFilePath);
        g_nSongsAdded++;
        return true;
    }
    return false;
}

public Native_AddToQueue(Handle:plugin, numParams) {
    decl String:rgsSongData[3][PLATFORM_MAX_PATH];
    
    for (new i = 0; i < 3; i++) {
        GetNativeString(i+1, rgsSongData[i], PLATFORM_MAX_PATH);
    }
    
    return AddToQueue(rgsSongData[ARRAY_ARTIST], rgsSongData[ARRAY_TITLE], rgsSongData[ARRAY_FILEPATH]);
}

public Action:Command_PlaySong(client, args) {
    new iTrack;
    if (args > 0) {
        decl String:num[4];
        GetCmdArg(1, num, sizeof(num));
        iTrack = StringToInt(num) % GetActiveSongCount();
    } else {
        iTrack = GetNextSong();
    }

    PlayEndRoundSong(iTrack);
    return Plugin_Handled;
}

public Action:Command_RerollSongs(client, args) {
    PrintToServer("[rem] Songlist requeued by %N -- be sure to reconnect.", client);
    QueueSongs();
    return Plugin_Handled;
}

public Action:Command_DisplaySongList(client, args) {
    new Handle:hMenu = CreateMenu(MenuHandler_SongList, MENU_ACTIONS_DEFAULT);
    SetMenuTitle(hMenu, "What we have playing on this map:\n(Unplayed songs roll over to the next map.)");
    
    decl String:sMenuBuffer[64];
    decl String:sMenuItemBuffer[16];
    
    if (g_bPluginEnabled) {
        decl String:rgsSongData[2][PLATFORM_MAX_PATH];
        for (new i = 0; i < GetActiveSongCount(); i++) {
            for (new d = 0; d < 2; d++) {
                GetArrayString(g_hSongData[d], i, rgsSongData[d], sizeof(rgsSongData[]));
            }
            Format(sMenuBuffer, sizeof(sMenuBuffer), "'%s' from %s",
                    rgsSongData[ARRAY_TITLE], rgsSongData[ARRAY_ARTIST]);
            // TODO restrict size of entry
            // TODO Spit detailed output to console.
            
            Format(sMenuItemBuffer, sizeof(sMenuItemBuffer), "#songlist_%d", i);
            AddMenuItem(hMenu, sMenuItemBuffer, sMenuBuffer);
        }
    } else {
        AddMenuItem(hMenu, "#songlist_disabled", "Songs are currently disabled!", ITEMDRAW_DISABLED);
    }
    SetMenuExitButton(hMenu, true);

    DisplayMenu(hMenu, client, 20);
    return Plugin_Handled;
}

public MenuHandler_SongList(Handle:hMenu, MenuAction:hAction, client, selection) {
    if (hAction == MenuAction_Select) {
        decl String:sMenuSelected[16];
        GetMenuItem(hMenu, selection, sMenuSelected, sizeof(sMenuSelected));
        
        decl String:sMenuItemBuffer[16];
        for (new i = 0; i < GetActiveSongCount(); i++) {
            Format(sMenuItemBuffer, sizeof(sMenuItemBuffer), "#songlist_%d", i);
            if (StrEqual(sMenuSelected, sMenuItemBuffer)) {
                decl String:sSongPath[PLATFORM_MAX_PATH];
                GetArrayString(g_hSongData[ARRAY_FILEPATH], i, sSongPath, sizeof(sSongPath));
                
                EmitSoundToClient(client, sSongPath, _, _, _, _, g_rgfClientVolume[client]);
            }
        }
    }
}

public CookieMenu_RoundEndSongVolume(iClient, CookieMenuAction:action, any:info, String:sBuffer[], iBufferSize) {
    if (action != CookieMenuAction_DisplayOption) {
        DisplayVolumeMenu(iClient);
    }
}

public Action:Command_SetSongVolume(client, args) {
    if (args > 0) {
        decl String:sVolumeBuffer[8];
        GetCmdArg(1, sVolumeBuffer, sizeof(sVolumeBuffer));
        
        new Float:fVolumeLevel = StringToFloat(sVolumeBuffer);
        SetClientVolumeLevel(client,
                fVolumeLevel > 1.0 ? 1.0 : ( fVolumeLevel < 0.0 ? 0.0 : fVolumeLevel ));
    } else {
        DisplayVolumeMenu(client);
    }
    return Plugin_Handled;
}

DisplayVolumeMenu(client) {
    new Handle:hMenu = CreateMenu(MenuHandler_SongVolume);
        
    decl String:sPanelTitle[48];
    Format(sPanelTitle, sizeof(sPanelTitle), "Song volume (currently %01.2f):", g_rgfClientVolume[client]);
    SetMenuTitle(hMenu, sPanelTitle);
    
    decl String:sVolumeDisplay[24], String:sVolumeAmount[6];
    for (new i = 10; i > 0; i -= 2) {
        Format(sVolumeDisplay, sizeof(sVolumeDisplay), "%d%% Volume", i * 10);
        Format(sVolumeAmount, sizeof(sVolumeAmount), "%0.2f", i / 10);
        AddMenuItem(hMenu, sVolumeAmount, sVolumeDisplay);
    }
    AddMenuItem(hMenu, "0.00", "Disable Round End Music");   // Option 6
    SetMenuExitBackButton(hMenu, true); 

    DisplayMenu(hMenu, client, 20);
}

public MenuHandler_SongVolume(Handle:hMenu, MenuAction:action, iClient, selection) {
    if (action == MenuAction_Select) {
        if (selection != 7) {
            new Float:fVolumeLevel = 0.2 * (5 - selection);
            SetClientVolumeLevel(iClient, fVolumeLevel);
        }
    } else if (action == MenuAction_Cancel) {
        if (selection == MenuCancel_ExitBack) {
            ShowCookieMenu(iClient);
        }
    } else if (action == MenuAction_End) {
        CloseHandle(hMenu); 
    }
}

SetClientVolumeLevel(client, Float:fVolumeLevel) {
    decl String:sVolumeLevel[8];
    Format(sVolumeLevel, sizeof(sVolumeLevel), "%f", fVolumeLevel);
    
    g_rgfClientVolume[client] = fVolumeLevel;
    SetClientCookie(client, g_hVolumeCookie, sVolumeLevel);
    
    if (fVolumeLevel > 0.0) {
        PrintToChat(client, "[SM] Round End Music volume set to %01.2f.", fVolumeLevel);
    } else {
        PrintToChat(client, "[SM] Round End Music muted.");
    }
}

public OnConVarChanged(Handle:convar, const String:sOldValue[], const String:sNewValue[]) {
    if (convar == g_hCSongPlayDelay) {
        g_fSongPlayDelay = StringToFloat(sNewValue);
    }
}

GetListeningPlayerCount() {
    new nPlayers;
    for (new i = MaxClients; i > 0; --i) {
        if (IsClientInGame(i) && !IsFakeClient(i) && FloatCompare(g_rgfClientVolume[i], 0.0) == 1) {
            nPlayers++;
        }
    }
    return nPlayers;
}
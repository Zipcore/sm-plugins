#include <sourcemod>
#include <sdkhooks>
#include <clientprefs>

#define PLUGIN_VERSION "1.0.1"

public Plugin:myinfo = {
    name = "Hitsounds for Buildings (+clientprefs)",
    author = "MasterOfTheXP, nosoop",
    description = "Adds the hit notification onto buildings.",
    version = PLUGIN_VERSION,
    url = "http://mstr.ca/"
};

new Handle:g_hHitsoundCookie = INVALID_HANDLE,
    bool:g_bBuildingHitsounds[MAXPLAYERS+1];

public OnPluginStart() {
    g_hHitsoundCookie = RegClientCookie("BuildingHitsounds", "Enable hitsounds and damage text on buildings.", CookieAccess_Protected);
    SetCookiePrefabMenu(g_hHitsoundCookie, CookieMenu_OnOff_Int, "Building Hitsounds", CookieHandler_BuildingHitsounds);
    
    for (new i = MaxClients; i > 0; --i) {
        if (!AreClientCookiesCached(i)) {
            continue;
        }
        OnClientCookiesCached(i);
    }
}

public OnClientCookiesCached(client) {
    decl String:sValue[8];
    GetClientCookie(client, g_hHitsoundCookie, sValue, sizeof(sValue));
    
    g_bBuildingHitsounds[client] = (sValue[0] != '\0' && StringToInt(sValue) > 0);
}  
    
public OnEntityCreated(entity, const String:cls[]) {
    if (StrEqual(cls, "obj_sentrygun") || StrEqual(cls, "obj_dispenser") || StrEqual(cls, "obj_teleporter") /* || StrEqual(cls, "obj_attachment_sapper")*/) {
        SDKHook(entity, SDKHook_OnTakeDamage, Hook_BuildingOnTakeDamage);
    }
}

public Action:Hook_BuildingOnTakeDamage(entity, &attacker, &inflictor, &Float:damage, &damagetype, &weapon, Float:damageForce[3], Float:damagePosition[3]) {
    if (!IsValidClient(attacker) || IsFakeClient(attacker)) {
        return Plugin_Continue;
    } else if (g_bBuildingHitsounds[attacker]) {
        new Handle:hEventBuildingHurt = CreateEvent("npc_hurt", true);
        
        SetEventInt(hEventBuildingHurt, "attacker_player", GetClientUserId(attacker));
        SetEventInt(hEventBuildingHurt, "entindex", entity);
        
        new dmg = RoundFloat(damage),
            activeWep = GetEntPropEnt(attacker, Prop_Send, "m_hActiveWeapon"),
            idx;
            
        if (IsValidEntity(activeWep)) {
            idx = GetEntProp(activeWep, Prop_Send, "m_iItemDefinitionIndex");
        }
        
        if (idx == 153) {
            dmg *= 2;
        } else if (idx == 441 || idx == 442 || idx == 588) {
            dmg = RoundFloat(float(dmg) * 0.2);
        }
        
        SetEventInt(hEventBuildingHurt, "damageamount", dmg);
        FireEvent(hEventBuildingHurt);
    }
    return Plugin_Continue;
}

stock bool:IsValidClient(client) {
    if (client <= 0 || client > MaxClients) return false;
    if (!IsClientInGame(client)) return false;
    if (IsClientSourceTV(client) || IsClientReplay(client)) return false;
    return true;
}

public CookieHandler_BuildingHitsounds(client, CookieMenuAction:action, any:info, String:buffer[], maxlen) {
    switch (action) {
        case CookieMenuAction_DisplayOption: {
        }
        case CookieMenuAction_SelectOption: {
            OnClientCookiesCached(client);
        }
    }
} 
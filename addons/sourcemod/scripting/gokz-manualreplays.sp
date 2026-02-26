#include <sourcemod>
#include <sdktools>

#include <movementapi>

#include <gokz/core>
#include <gokz/replays>

#pragma newdecls required
#pragma semicolon 1

public Plugin myinfo =
{
	name = "GOKZ Manual Replays",
	author = "sourdirt",
	description = "Standalone manual replay recorder/browser for GOKZ",
	version = "1.0.1a",
	url = "https://github.com/sourdirt"
};

static bool gB_Recording[MAXPLAYERS + 1];
static float gF_RecordingStartTime[MAXPLAYERS + 1];
static bool gB_IsTeleportTick[MAXPLAYERS + 1];
static float gF_PlayerSensitivity[MAXPLAYERS + 1];
static float gF_PlayerMYaw[MAXPLAYERS + 1];
static float gF_Tickrate;

static int gI_SelectedMode[MAXPLAYERS + 1];
static ArrayList gA_RecordedData[MAXPLAYERS + 1];
static ArrayList gA_ManualReplayPaths[MAXPLAYERS + 1];

public void OnPluginStart()
{
	RegConsoleCmd("sm_manualrecord", Command_ManualRecord, "[KZ] Toggle manual replay recording.");
	RegConsoleCmd("sm_manualreplay", Command_ManualReplay, "[KZ] Open manual replay menu.");

	gF_Tickrate = 1.0 / GetTickInterval();
	CreateManualReplayDirectory();
}

public void OnMapStart()
{
	CreateManualReplayDirectory();
}

public void OnClientPutInServer(int client)
{
	if (gA_RecordedData[client] == null)
	{
		gA_RecordedData[client] = new ArrayList(sizeof(ReplayTickData));
	}
	else
	{
		gA_RecordedData[client].Clear();
	}

	if (gA_ManualReplayPaths[client] == null)
	{
		gA_ManualReplayPaths[client] = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));
	}
	else
	{
		gA_ManualReplayPaths[client].Clear();
	}

	gB_Recording[client] = false;
	gB_IsTeleportTick[client] = false;
	gF_RecordingStartTime[client] = 0.0;
	gF_PlayerSensitivity[client] = -1.0;
	gF_PlayerMYaw[client] = -1.0;
}

public void OnClientAuthorized(int client, const char[] auth)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return;
	}

	CreateManualReplayDirectoryForClient(client);
}

public void OnClientDisconnect(int client)
{
	gB_Recording[client] = false;
	gB_IsTeleportTick[client] = false;
	if (gA_RecordedData[client] != null)
	{
		gA_RecordedData[client].Clear();
	}
	if (gA_ManualReplayPaths[client] != null)
	{
		gA_ManualReplayPaths[client].Clear();
	}
}

public void OnPlayerRunCmdPost(int client, int buttons, int impulse, const float vel[3], const float angles[3], int weapon, int subtype, int cmdnum, int tickcount, int seed, const int mouse[2])
{
	if (!gB_Recording[client] || !IsValidClient(client) || IsFakeClient(client) || !IsPlayerAlive(client))
	{
		return;
	}

	ReplayTickData tickData;
	Movement_GetOrigin(client, tickData.origin);
	tickData.mouse = mouse;
	tickData.vel = vel;
	Movement_GetVelocity(client, tickData.velocity);
	Movement_GetEyeAngles(client, tickData.angles);
	tickData.flags = EncodePlayerFlags(client, buttons, tickcount);
	tickData.packetsPerSecond = GetClientAvgPackets(client, NetFlow_Incoming);
	tickData.laggedMovementValue = GetEntPropFloat(client, Prop_Send, "m_flLaggedMovementValue");
	tickData.buttonsForced = GetEntProp(client, Prop_Data, "m_afButtonForced");

	gA_RecordedData[client].PushArray(tickData);
	gB_IsTeleportTick[client] = false;
}

public void GOKZ_OnCountedTeleport_Post(int client)
{
	gB_IsTeleportTick[client] = true;
}

public Action Command_ManualRecord(int client, int args)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return Plugin_Handled;
	}

	if (gB_Recording[client])
	{
		char savedPath[PLATFORM_MAX_PATH];
		float elapsed = 0.0;
		if (StopManualRecording(client, savedPath, sizeof(savedPath), elapsed))
		{
			PrintToChat(client, "[KZ] Manual recording stopped and saved.");
			PrintToConsole(client, "[KZ] Manual recording stopped and saved.");
			PrintToConsole(client, "[KZ] Duration: %.3f seconds", elapsed);
			PrintToConsole(client, "[KZ] File: %s", savedPath);
		}
		else
		{
			PrintToChat(client, "[KZ] Manual recording stopped.");
			PrintToConsole(client, "[KZ] Manual recording stopped.");
		}
	}
	else
	{
		if (!IsPlayerAlive(client))
		{
			PrintToChat(client, "[KZ] You must be alive to start manual recording.");
			return Plugin_Handled;
		}

		StartManualRecording(client);
		PrintToChat(client, "[KZ] Manual recording started.");
		PrintToConsole(client, "[KZ] Manual recording started.");
	}

	return Plugin_Handled;
}

public Action Command_ManualReplay(int client, int args)
{
	if (!IsValidClient(client) || IsFakeClient(client))
	{
		return Plugin_Handled;
	}

	DisplayManualReplayModeMenu(client);
	return Plugin_Handled;
}

public int MenuHandler_ManualMode(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		char info[8];
		menu.GetItem(item, info, sizeof(info));
		gI_SelectedMode[client] = StringToInt(info);
		DisplayManualReplayMenu(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}
	return 0;
}

public int MenuHandler_ManualReplay(Menu menu, MenuAction action, int client, int item)
{
	if (action == MenuAction_Select)
	{
		if (gA_ManualReplayPaths[client] == null)
		{
			return 0;
		}

		char info[12];
		menu.GetItem(item, info, sizeof(info));
		int index = StringToInt(info);
		if (index < 0 || index >= gA_ManualReplayPaths[client].Length)
		{
			return 0;
		}

		char path[PLATFORM_MAX_PATH];
		gA_ManualReplayPaths[client].GetString(index, path, sizeof(path));
		if (!FileExists(path))
		{
			PrintToChat(client, "[KZ] Replay file missing.");
			return 0;
		}

		int bot = GOKZ_RP_LoadJumpReplay(client, path);
		if (bot < 1)
		{
			PrintToChat(client, "[KZ] Could not load replay bot. Is gokz-replays loaded?");
		}
	}
	else if (action == MenuAction_Cancel)
	{
		DisplayManualReplayModeMenu(client);
	}
	else if (action == MenuAction_End)
	{
		delete menu;
	}

	return 0;
}

static void StartManualRecording(int client)
{
	CreateManualReplayDirectoryForClient(client);

	gA_RecordedData[client].Clear();
	gF_RecordingStartTime[client] = GetEngineTime();
	gB_Recording[client] = true;
	QueryClientConVar(client, "sensitivity", CvarQuery_Sensitivity, client);
	QueryClientConVar(client, "m_yaw", CvarQuery_MYaw, client);
}

static bool StopManualRecording(int client, char[] savedPath, int savedPathMaxLength, float &elapsed)
{
	gB_Recording[client] = false;
	savedPath[0] = '\0';
	elapsed = 0.0;
	if (gA_RecordedData[client] == null || gA_RecordedData[client].Length == 0)
	{
		return false;
	}
	return SaveManualReplay(client, savedPath, savedPathMaxLength, elapsed);
}

static bool SaveManualReplay(int client, char[] savedPath, int savedPathMaxLength, float &elapsed)
{
	float time = GetEngineTime() - gF_RecordingStartTime[client];
	if (time < 0.0)
	{
		time = 0.0;
	}
	elapsed = time;

	GeneralReplayHeader header;
	FillGeneralHeader(header, client, ReplayType_Run, gA_RecordedData[client].Length);

	RunReplayHeader runHeader;
	runHeader.time = time;
	runHeader.course = GOKZ_GetCourse(client);
	runHeader.teleportsUsed = GOKZ_GetTeleportCount(client);

	char path[PLATFORM_MAX_PATH];
	FormatManualReplayPath(path, sizeof(path), client, header.mode, header.style);

	File file = OpenFile(path, "wb");
	if (file == null)
	{
		LogError("Could not write manual replay file: %s", path);
		return false;
	}

	WriteGeneralHeader(file, header);
	file.WriteInt32(view_as<int>(runHeader.time));
	file.WriteInt8(runHeader.course);
	file.WriteInt32(runHeader.teleportsUsed);
	WriteRecordedTickData(file, client);
	delete file;

	strcopy(savedPath, savedPathMaxLength, path);
	return true;
}

static void FillGeneralHeader(GeneralReplayHeader header, int client, int replayType, int tickCount)
{
	char mapName[64];
	GetCurrentMapDisplayName(mapName, sizeof(mapName));

	header.magicNumber = RP_MAGIC_NUMBER;
	header.formatVersion = RP_FORMAT_VERSION;
	header.replayType = replayType;
	header.gokzVersion = GOKZ_VERSION;
	header.mapName = mapName;
	header.mapFileSize = 0;
	header.serverIP = FindConVar("hostip").IntValue;
	header.timestamp = GetTime();
	GetClientName(client, header.playerAlias, sizeof(GeneralReplayHeader::playerAlias));
	header.playerSteamID = GetSteamAccountID(client);
	header.mode = GOKZ_GetCoreOption(client, Option_Mode);
	header.style = GOKZ_GetCoreOption(client, Option_Style);
	header.playerSensitivity = gF_PlayerSensitivity[client];
	header.playerMYaw = gF_PlayerMYaw[client];
	header.tickrate = gF_Tickrate;
	header.tickCount = tickCount;
	header.equippedWeapon = GetPlayerWeaponSlotDefIndex(client, CS_SLOT_SECONDARY);
	header.equippedKnife = GetPlayerWeaponSlotDefIndex(client, CS_SLOT_KNIFE);
}

static void WriteGeneralHeader(File file, GeneralReplayHeader header)
{
	file.WriteInt32(header.magicNumber);
	file.WriteInt8(header.formatVersion);
	file.WriteInt8(header.replayType);
	file.WriteInt8(strlen(header.gokzVersion));
	file.WriteString(header.gokzVersion, false);
	file.WriteInt8(strlen(header.mapName));
	file.WriteString(header.mapName, false);
	file.WriteInt32(header.mapFileSize);
	file.WriteInt32(header.serverIP);
	file.WriteInt32(header.timestamp);
	file.WriteInt8(strlen(header.playerAlias));
	file.WriteString(header.playerAlias, false);
	file.WriteInt32(header.playerSteamID);
	file.WriteInt8(header.mode);
	file.WriteInt8(header.style);
	file.WriteInt32(view_as<int>(header.playerSensitivity));
	file.WriteInt32(view_as<int>(header.playerMYaw));
	file.WriteInt32(view_as<int>(header.tickrate));
	file.WriteInt32(header.tickCount);
	file.WriteInt32(header.equippedWeapon);
	file.WriteInt32(header.equippedKnife);
}

static void WriteRecordedTickData(File file, int client)
{
	ReplayTickData tickData;
	ReplayTickData prevTickData;
	bool first = true;
	for (int i = 0; i < gA_RecordedData[client].Length; i++)
	{
		gA_RecordedData[client].GetArray(i, tickData);
		gA_RecordedData[client].GetArray(IntMax(0, i - 1), prevTickData);
		WriteTickDataToFile(file, first, tickData, prevTickData);
		first = false;
	}
}

static void WriteTickDataToFile(File file, bool isFirstTick, ReplayTickData tickDataStruct, ReplayTickData prevTickDataStruct)
{
	any tickData[RP_V2_TICK_DATA_BLOCKSIZE];
	any prevTickData[RP_V2_TICK_DATA_BLOCKSIZE];
	TickDataToArray(tickDataStruct, tickData);
	TickDataToArray(prevTickDataStruct, prevTickData);

	int deltaFlags = (1 << RPDELTA_DELTAFLAGS);
	if (isFirstTick)
	{
		deltaFlags = (1 << RP_V2_TICK_DATA_BLOCKSIZE) - 1;
	}
	else
	{
		for (int i = 1; i < sizeof(tickData); i++)
		{
			if (tickData[i] ^ prevTickData[i])
			{
				deltaFlags |= (1 << i);
			}
		}
	}

	file.WriteInt32(deltaFlags);
	for (int i = 1; i < sizeof(tickData); i++)
	{
		if (deltaFlags & (1 << i))
		{
			file.WriteInt32(tickData[i]);
		}
	}
}

static void TickDataToArray(ReplayTickData tickData, any result[RP_V2_TICK_DATA_BLOCKSIZE])
{
	result[0] = tickData.deltaFlags;
	result[1] = tickData.deltaFlags2;
	result[2] = tickData.vel[0];
	result[3] = tickData.vel[1];
	result[4] = tickData.vel[2];
	result[5] = tickData.mouse[0];
	result[6] = tickData.mouse[1];
	result[7] = tickData.origin[0];
	result[8] = tickData.origin[1];
	result[9] = tickData.origin[2];
	result[10] = tickData.angles[0];
	result[11] = tickData.angles[1];
	result[12] = tickData.angles[2];
	result[13] = tickData.velocity[0];
	result[14] = tickData.velocity[1];
	result[15] = tickData.velocity[2];
	result[16] = tickData.flags;
	result[17] = tickData.packetsPerSecond;
	result[18] = tickData.laggedMovementValue;
	result[19] = tickData.buttonsForced;
}

static int EncodePlayerFlags(int client, int buttons, int tickCount)
{
	int flags = view_as<int>(Movement_GetMovetype(client)) & RP_MOVETYPE_MASK;
	int clientFlags = GetEntityFlags(client);

	SetKthBit(flags, 4, IsBitSet(buttons, IN_ATTACK));
	SetKthBit(flags, 5, IsBitSet(buttons, IN_ATTACK2));
	SetKthBit(flags, 6, IsBitSet(buttons, IN_JUMP));
	SetKthBit(flags, 7, IsBitSet(buttons, IN_DUCK));
	SetKthBit(flags, 8, IsBitSet(buttons, IN_FORWARD));
	SetKthBit(flags, 9, IsBitSet(buttons, IN_BACK));
	SetKthBit(flags, 10, IsBitSet(buttons, IN_LEFT));
	SetKthBit(flags, 11, IsBitSet(buttons, IN_RIGHT));
	SetKthBit(flags, 12, IsBitSet(buttons, IN_MOVELEFT));
	SetKthBit(flags, 13, IsBitSet(buttons, IN_MOVERIGHT));
	SetKthBit(flags, 14, IsBitSet(buttons, IN_RELOAD));
	SetKthBit(flags, 15, IsBitSet(buttons, IN_SPEED));
	SetKthBit(flags, 16, IsBitSet(buttons, IN_USE));
	SetKthBit(flags, 17, IsBitSet(buttons, IN_BULLRUSH));
	SetKthBit(flags, 18, IsBitSet(clientFlags, FL_ONGROUND));
	SetKthBit(flags, 19, IsBitSet(clientFlags, FL_DUCKING));
	SetKthBit(flags, 20, IsBitSet(clientFlags, FL_SWIM));
	SetKthBit(flags, 21, GetEntProp(client, Prop_Data, "m_nWaterLevel") != 0);
	SetKthBit(flags, 22, gB_IsTeleportTick[client]);
	SetKthBit(flags, 23, Movement_GetTakeoffTick(client) == tickCount);
	SetKthBit(flags, 24, GOKZ_GetHitPerf(client));
	SetKthBit(flags, 25, IsCurrentWeaponSecondary(client));

	return flags;
}

static void SetKthBit(int &number, int offset, bool value)
{
	number |= (value ? 1 : 0) << offset;
}

static bool IsBitSet(int number, int checkBit)
{
	return (number & checkBit) != 0;
}

static int GetPlayerWeaponSlotDefIndex(int client, int slot)
{
	int ent = GetPlayerWeaponSlot(client, slot);
	if (ent == -1)
	{
		return -1;
	}
	return GetEntProp(ent, Prop_Send, "m_iItemDefinitionIndex");
}

static bool IsCurrentWeaponSecondary(int client)
{
	int activeWeaponEnt = GetEntPropEnt(client, Prop_Send, "m_hActiveWeapon");
	int secondaryEnt = GetPlayerWeaponSlot(client, CS_SLOT_SECONDARY);
	return activeWeaponEnt == secondaryEnt;
}

static void CreateManualReplayDirectory()
{
	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), RP_DIRECTORY);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}
	BuildPath(Path_SM, path, sizeof(path), RP_DIRECTORY_MANUAL);
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}
}

static void CreateManualReplayDirectoryForClient(int client)
{
	if (GetSteamAccountID(client) == 0)
	{
		return;
	}

	char path[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, path, sizeof(path), "%s/%d", RP_DIRECTORY_MANUAL, GetSteamAccountID(client));
	if (!DirExists(path))
	{
		CreateDirectory(path, 511);
	}
}

static void FormatManualReplayPath(char[] buffer, int maxlength, int client, int mode, int style)
{
	char mapName[64];
	GetCurrentMapDisplayName(mapName, sizeof(mapName));
	BuildPath(Path_SM, buffer, maxlength,
		"%s/%d/%s_%d_%s_%s.%s",
		RP_DIRECTORY_MANUAL,
		GetSteamAccountID(client),
		mapName,
		GetTime(),
		gC_ModeNamesShort[mode],
		gC_StyleNamesShort[style],
		RP_FILE_EXTENSION);
}

static void DisplayManualReplayModeMenu(int client)
{
	char clientPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, clientPath, sizeof(clientPath), "%s/%d", RP_DIRECTORY_MANUAL, GetSteamAccountID(client));
	if (!DirExists(clientPath))
	{
		PrintToChat(client, "[KZ] No manual replays found.");
		return;
	}

	Menu menu = new Menu(MenuHandler_ManualMode);
	menu.SetTitle("Manual Replays\n \nSelect a mode");
	menu.ExitButton = true;

	for (int mode = 0; mode < MODE_COUNT; mode++)
	{
		char info[8];
		IntToString(mode, info, sizeof(info));
		int draw = CountManualReplaysForMode(client, mode) > 0 ? ITEMDRAW_DEFAULT : ITEMDRAW_DISABLED;
		menu.AddItem(info, gC_ModeNames[mode], draw);
	}

	menu.Display(client, MENU_TIME_FOREVER);
}

static void DisplayManualReplayMenu(int client)
{
	Menu menu = new Menu(MenuHandler_ManualReplay);
	char title[128];
	FormatEx(title, sizeof(title), "Manual Replays\n \nMode - %s", gC_ModeNames[gI_SelectedMode[client]]);
	menu.SetTitle(title);
	menu.ExitBackButton = true;

	if (BuildManualReplayMenuItems(client, menu) > 0)
	{
		menu.Display(client, MENU_TIME_FOREVER);
	}
	else
	{
		delete menu;
		PrintToChat(client, "[KZ] No manual replays found for this mode.");
		DisplayManualReplayModeMenu(client);
	}
}

static int BuildManualReplayMenuItems(int client, Menu menu)
{
	gA_ManualReplayPaths[client].Clear();

	char clientPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, clientPath, sizeof(clientPath), "%s/%d", RP_DIRECTORY_MANUAL, GetSteamAccountID(client));
	DirectoryListing dir = OpenDirectory(clientPath);
	if (dir == null)
	{
		return 0;
	}

	ArrayList stamps = new ArrayList();
	ArrayList styles = new ArrayList();
	ArrayList maps = new ArrayList(ByteCountToCells(64));
	ArrayList paths = new ArrayList(ByteCountToCells(PLATFORM_MAX_PATH));

	char file[PLATFORM_MAX_PATH], fullPath[PLATFORM_MAX_PATH], mapName[64], modeShort[16], styleShort[16], stamp[16];
	FileType type;
	while (dir.GetNext(file, sizeof(file), type))
	{
		if (type != FileType_File)
		{
			continue;
		}
		if (!ParseManualFilename(file, mapName, sizeof(mapName), stamp, sizeof(stamp), modeShort, sizeof(modeShort), styleShort, sizeof(styleShort)))
		{
			continue;
		}

		int modeID = GetModeIDFromShortName(modeShort);
		int styleID = GetStyleIDFromShortName(styleShort);
		if (modeID != gI_SelectedMode[client] || styleID == -1)
		{
			continue;
		}

		BuildPath(Path_SM, fullPath, sizeof(fullPath), "%s/%d/%s", RP_DIRECTORY_MANUAL, GetSteamAccountID(client), file);
		stamps.Push(StringToInt(stamp));
		styles.Push(styleID);
		maps.PushString(mapName);
		paths.PushString(fullPath);
	}
	delete dir;

	int added = 0;
	char info[12], display[128], mapOut[64], pathOut[PLATFORM_MAX_PATH], date[32];
	while (stamps.Length > 0)
	{
		int newest = 0;
		int newestStamp = stamps.Get(0);
		for (int i = 1; i < stamps.Length; i++)
		{
			int s = stamps.Get(i);
			if (s > newestStamp)
			{
				newest = i;
				newestStamp = s;
			}
		}

		maps.GetString(newest, mapOut, sizeof(mapOut));
		paths.GetString(newest, pathOut, sizeof(pathOut));
		int styleID = styles.Get(newest);

		gA_ManualReplayPaths[client].PushString(pathOut);
		IntToString(added, info, sizeof(info));
		FormatTime(date, sizeof(date), "%Y-%m-%d %H:%M", newestStamp);
		FormatEx(display, sizeof(display), "%s | %s | %s", mapOut, gC_StyleNames[styleID], date);
		menu.AddItem(info, display);
		added++;

		stamps.Erase(newest);
		styles.Erase(newest);
		maps.Erase(newest);
		paths.Erase(newest);
	}

	delete stamps;
	delete styles;
	delete maps;
	delete paths;

	return added;
}

static int CountManualReplaysForMode(int client, int mode)
{
	char clientPath[PLATFORM_MAX_PATH];
	BuildPath(Path_SM, clientPath, sizeof(clientPath), "%s/%d", RP_DIRECTORY_MANUAL, GetSteamAccountID(client));
	DirectoryListing dir = OpenDirectory(clientPath);
	if (dir == null)
	{
		return 0;
	}

	int count = 0;
	char file[PLATFORM_MAX_PATH], mapName[64], modeShort[16], styleShort[16], stamp[16];
	FileType type;
	while (dir.GetNext(file, sizeof(file), type))
	{
		if (type != FileType_File)
		{
			continue;
		}
		if (!ParseManualFilename(file, mapName, sizeof(mapName), stamp, sizeof(stamp), modeShort, sizeof(modeShort), styleShort, sizeof(styleShort)))
		{
			continue;
		}
		if (GetModeIDFromShortName(modeShort) == mode)
		{
			count++;
		}
	}
	delete dir;
	return count;
}

static bool ParseManualFilename(const char[] file, char[] mapName, int mapNameLen, char[] stamp, int stampLen, char[] modeShort, int modeLen, char[] styleShort, int styleLen)
{
	if (!HasReplayExtension(file))
	{
		return false;
	}

	char base[PLATFORM_MAX_PATH];
	strcopy(base, sizeof(base), file);

	int dot = -1;
	for (int i = strlen(base) - 1; i >= 0; i--)
	{
		if (base[i] == '.')
		{
			dot = i;
			break;
		}
	}
	if (dot < 0)
	{
		return false;
	}
	base[dot] = '\0';

	int u3 = -1;
	for (int i = strlen(base) - 1; i >= 0; i--)
	{
		if (base[i] == '_')
		{
			u3 = i;
			break;
		}
	}
	if (u3 < 1)
	{
		return false;
	}
	int u2 = -1;
	for (int i = u3 - 1; i >= 0; i--)
	{
		if (base[i] == '_')
		{
			u2 = i;
			break;
		}
	}
	if (u2 < 1)
	{
		return false;
	}
	int u1 = -1;
	for (int i = u2 - 1; i >= 0; i--)
	{
		if (base[i] == '_')
		{
			u1 = i;
			break;
		}
	}
	if (u1 < 1)
	{
		return false;
	}

	base[u3] = '\0';
	base[u2] = '\0';
	base[u1] = '\0';
	strcopy(mapName, mapNameLen, base);
	strcopy(stamp, stampLen, base[u1 + 1]);
	strcopy(modeShort, modeLen, base[u2 + 1]);
	strcopy(styleShort, styleLen, base[u3 + 1]);
	return true;
}

static bool HasReplayExtension(const char[] file)
{
	int dot = -1;
	for (int i = strlen(file) - 1; i >= 0; i--)
	{
		if (file[i] == '.')
		{
			dot = i;
			break;
		}
	}
	return dot > -1 && StrEqual(file[dot + 1], RP_FILE_EXTENSION, false);
}

static int GetModeIDFromShortName(const char[] modeShort)
{
	for (int i = 0; i < MODE_COUNT; i++)
	{
		if (StrEqual(gC_ModeNamesShort[i], modeShort, false))
		{
			return i;
		}
	}
	return -1;
}

static int GetStyleIDFromShortName(const char[] styleShort)
{
	for (int i = 0; i < STYLE_COUNT; i++)
	{
		if (StrEqual(gC_StyleNamesShort[i], styleShort, false))
		{
			return i;
		}
	}
	return -1;
}

public void CvarQuery_Sensitivity(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, any value)
{
	if (IsValidClient(client) && !IsFakeClient(client))
	{
		gF_PlayerSensitivity[client] = StringToFloat(cvarValue);
	}
}

public void CvarQuery_MYaw(QueryCookie cookie, int client, ConVarQueryResult result, const char[] cvarName, const char[] cvarValue, any value)
{
	if (IsValidClient(client) && !IsFakeClient(client))
	{
		gF_PlayerMYaw[client] = StringToFloat(cvarValue);
	}
}

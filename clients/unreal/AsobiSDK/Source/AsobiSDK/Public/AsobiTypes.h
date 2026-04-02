#pragma once

#include "CoreMinimal.h"
#include "AsobiTypes.generated.h"

USTRUCT(BlueprintType)
struct FAsobiPlayer
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString Username;
	UPROPERTY(BlueprintReadOnly) FString DisplayName;
	UPROPERTY(BlueprintReadOnly) FString AvatarUrl;
	UPROPERTY(BlueprintReadOnly) FString MetadataJson;
	UPROPERTY(BlueprintReadOnly) FString InsertedAt;
	UPROPERTY(BlueprintReadOnly) FString UpdatedAt;
};

USTRUCT(BlueprintType)
struct FAsobiPlayerStats
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString PlayerId;
	UPROPERTY(BlueprintReadOnly) int32 GamesPlayed = 0;
	UPROPERTY(BlueprintReadOnly) int32 Wins = 0;
	UPROPERTY(BlueprintReadOnly) int32 Losses = 0;
	UPROPERTY(BlueprintReadOnly) float Rating = 1500.0f;
	UPROPERTY(BlueprintReadOnly) float RatingDeviation = 350.0f;
	UPROPERTY(BlueprintReadOnly) FString UpdatedAt;
};

USTRUCT(BlueprintType)
struct FAsobiAuthTokens
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString AccessToken;
	UPROPERTY(BlueprintReadOnly) FString RefreshToken;
	UPROPERTY(BlueprintReadOnly) FString PlayerId;
};

USTRUCT(BlueprintType)
struct FAsobiMatchRecord
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString Mode;
	UPROPERTY(BlueprintReadOnly) FString Status;
	UPROPERTY(BlueprintReadOnly) TArray<FString> Players;
	UPROPERTY(BlueprintReadOnly) FString StartedAt;
	UPROPERTY(BlueprintReadOnly) FString FinishedAt;
	UPROPERTY(BlueprintReadOnly) FString InsertedAt;
};

USTRUCT(BlueprintType)
struct FAsobiMatchmakerTicket
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString TicketId;
	UPROPERTY(BlueprintReadOnly) FString Status;
};

USTRUCT(BlueprintType)
struct FAsobiWallet
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString PlayerId;
	UPROPERTY(BlueprintReadOnly) FString Currency;
	UPROPERTY(BlueprintReadOnly) int64 Balance = 0;
	UPROPERTY(BlueprintReadOnly) FString InsertedAt;
	UPROPERTY(BlueprintReadOnly) FString UpdatedAt;
};

USTRUCT(BlueprintType)
struct FAsobiTransaction
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString WalletId;
	UPROPERTY(BlueprintReadOnly) int64 Amount = 0;
	UPROPERTY(BlueprintReadOnly) int64 BalanceAfter = 0;
	UPROPERTY(BlueprintReadOnly) FString Reason;
	UPROPERTY(BlueprintReadOnly) FString ReferenceType;
	UPROPERTY(BlueprintReadOnly) FString ReferenceId;
	UPROPERTY(BlueprintReadOnly) FString InsertedAt;
};

USTRUCT(BlueprintType)
struct FAsobiStoreListing
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString ItemDefId;
	UPROPERTY(BlueprintReadOnly) FString Currency;
	UPROPERTY(BlueprintReadOnly) int32 Price = 0;
	UPROPERTY(BlueprintReadOnly) bool bActive = true;
	UPROPERTY(BlueprintReadOnly) FString ValidFrom;
	UPROPERTY(BlueprintReadOnly) FString ValidUntil;
};

USTRUCT(BlueprintType)
struct FAsobiItemDef
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString Slug;
	UPROPERTY(BlueprintReadOnly) FString Name;
	UPROPERTY(BlueprintReadOnly) FString Category;
	UPROPERTY(BlueprintReadOnly) FString Rarity;
	UPROPERTY(BlueprintReadOnly) bool bStackable = true;
};

USTRUCT(BlueprintType)
struct FAsobiPlayerItem
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString ItemDefId;
	UPROPERTY(BlueprintReadOnly) FString PlayerId;
	UPROPERTY(BlueprintReadOnly) int32 Quantity = 1;
	UPROPERTY(BlueprintReadOnly) FString AcquiredAt;
	UPROPERTY(BlueprintReadOnly) FString UpdatedAt;
};

USTRUCT(BlueprintType)
struct FAsobiFriendship
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString PlayerId;
	UPROPERTY(BlueprintReadOnly) FString FriendId;
	UPROPERTY(BlueprintReadOnly) FString Status;
	UPROPERTY(BlueprintReadOnly) FString InsertedAt;
	UPROPERTY(BlueprintReadOnly) FString UpdatedAt;
};

USTRUCT(BlueprintType)
struct FAsobiGroup
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString Name;
	UPROPERTY(BlueprintReadOnly) FString Description;
	UPROPERTY(BlueprintReadOnly) int32 MaxMembers = 50;
	UPROPERTY(BlueprintReadOnly) bool bOpen = false;
	UPROPERTY(BlueprintReadOnly) FString CreatorId;
	UPROPERTY(BlueprintReadOnly) FString InsertedAt;
	UPROPERTY(BlueprintReadOnly) FString UpdatedAt;
};

USTRUCT(BlueprintType)
struct FAsobiLeaderboardEntry
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString LeaderboardId;
	UPROPERTY(BlueprintReadOnly) FString PlayerId;
	UPROPERTY(BlueprintReadOnly) int64 Score = 0;
	UPROPERTY(BlueprintReadOnly) int64 SubScore = 0;
	UPROPERTY(BlueprintReadOnly) int32 Rank = 0;
	UPROPERTY(BlueprintReadOnly) FString UpdatedAt;
};

USTRUCT(BlueprintType)
struct FAsobiCloudSave
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString PlayerId;
	UPROPERTY(BlueprintReadOnly) FString Slot;
	UPROPERTY(BlueprintReadOnly) int32 Version = 1;
	UPROPERTY(BlueprintReadOnly) FString UpdatedAt;
};

USTRUCT(BlueprintType)
struct FAsobiStorageObject
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString Collection;
	UPROPERTY(BlueprintReadOnly) FString Key;
	UPROPERTY(BlueprintReadOnly) FString PlayerId;
	UPROPERTY(BlueprintReadOnly) int32 Version = 1;
	UPROPERTY(BlueprintReadOnly) FString ReadPerm;
	UPROPERTY(BlueprintReadOnly) FString WritePerm;
	UPROPERTY(BlueprintReadOnly) FString UpdatedAt;
};

USTRUCT(BlueprintType)
struct FAsobiTournament
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString Name;
	UPROPERTY(BlueprintReadOnly) FString LeaderboardId;
	UPROPERTY(BlueprintReadOnly) int32 MaxEntries = 0;
	UPROPERTY(BlueprintReadOnly) FString Status;
	UPROPERTY(BlueprintReadOnly) FString StartAt;
	UPROPERTY(BlueprintReadOnly) FString EndAt;
	UPROPERTY(BlueprintReadOnly) FString InsertedAt;
};

USTRUCT(BlueprintType)
struct FAsobiNotification
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString PlayerId;
	UPROPERTY(BlueprintReadOnly) FString Type;
	UPROPERTY(BlueprintReadOnly) FString Subject;
	UPROPERTY(BlueprintReadOnly) bool bRead = false;
	UPROPERTY(BlueprintReadOnly) FString SentAt;
};

USTRUCT(BlueprintType)
struct FAsobiChatMessage
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString ChannelType;
	UPROPERTY(BlueprintReadOnly) FString ChannelId;
	UPROPERTY(BlueprintReadOnly) FString SenderId;
	UPROPERTY(BlueprintReadOnly) FString Content;
	UPROPERTY(BlueprintReadOnly) FString SentAt;
};

USTRUCT(BlueprintType)
struct FAsobiVote
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) FString Id;
	UPROPERTY(BlueprintReadOnly) FString MatchId;
	UPROPERTY(BlueprintReadOnly) FString Template;
	UPROPERTY(BlueprintReadOnly) FString Method;
	UPROPERTY(BlueprintReadOnly) float Turnout = 0.0f;
	UPROPERTY(BlueprintReadOnly) int32 EligibleCount = 0;
	UPROPERTY(BlueprintReadOnly) int32 WindowMs = 0;
	UPROPERTY(BlueprintReadOnly) FString OpenedAt;
	UPROPERTY(BlueprintReadOnly) FString ClosedAt;
	UPROPERTY(BlueprintReadOnly) FString InsertedAt;
};

USTRUCT(BlueprintType)
struct FAsobiError
{
	GENERATED_BODY()

	UPROPERTY(BlueprintReadOnly) int32 StatusCode = 0;
	UPROPERTY(BlueprintReadOnly) FString Reason;
};

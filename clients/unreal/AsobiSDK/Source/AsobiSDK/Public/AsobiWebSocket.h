#pragma once

#include "CoreMinimal.h"
#include "IWebSocket.h"
#include "AsobiTypes.h"
#include "AsobiWebSocket.generated.h"

DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOnAsobiWsConnected);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnAsobiWsDisconnected, const FString&, Reason);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FOnAsobiWsMessage, const FString&, Type, const FString&, Payload);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnAsobiWsError, const FString&, Error);

// Typed event delegates
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnAsobiMatchState, const FString&, StateJson);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FOnAsobiMatchEvent, const FString&, Event, const FString&, PayloadJson);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnAsobiMatchJoined, const FString&, InfoJson);
DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOnAsobiMatchLeft);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnAsobiMatchmakerQueued, const FString&, TicketId);
DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOnAsobiMatchmakerRemoved);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_TwoParams(FOnAsobiChatReceived, const FString&, ChannelId, const FString&, MessageJson);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnAsobiChatJoined, const FString&, ChannelId);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnAsobiChatLeft, const FString&, ChannelId);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnAsobiNotificationReceived, const FString&, NotifJson);
DECLARE_DYNAMIC_MULTICAST_DELEGATE_OneParam(FOnAsobiPresenceUpdated, const FString&, Status);
DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOnAsobiVoteCastOk);
DECLARE_DYNAMIC_MULTICAST_DELEGATE(FOnAsobiVoteVetoOk);

UCLASS(BlueprintType)
class ASOBISDK_API UAsobiWebSocket : public UObject
{
	GENERATED_BODY()

public:
	UAsobiWebSocket();

	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void Connect(const FString& Url);

	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void Disconnect();

	UFUNCTION(BlueprintPure, Category = "Asobi|WebSocket")
	bool IsConnected() const;

	// Session
	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void Authenticate(const FString& Token);

	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void SendHeartbeat();

	// Match
	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void SendMatchInput(const FString& DataJson);

	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void JoinMatch(const FString& MatchId);

	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void LeaveMatch();

	// Matchmaker
	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void MatchmakerAdd(const FString& Mode, const TArray<FString>& Party);

	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void MatchmakerRemove(const FString& TicketId);

	// Chat
	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void ChatJoin(const FString& ChannelId);

	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void ChatLeave(const FString& ChannelId);

	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void ChatSend(const FString& ChannelId, const FString& Content);

	// Presence
	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void UpdatePresence(const FString& Status);

	// Voting
	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void CastVote(const FString& VoteId, const FString& OptionId);

	UFUNCTION(BlueprintCallable, Category = "Asobi|WebSocket")
	void UseVeto(const FString& VoteId);

	// Connection events
	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiWsConnected OnConnected;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiWsDisconnected OnDisconnected;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiWsMessage OnMessage;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiWsError OnError;

	// Typed events
	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiMatchState OnMatchState;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiMatchEvent OnMatchEvent;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiMatchJoined OnMatchJoined;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiMatchLeft OnMatchLeft;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiMatchmakerQueued OnMatchmakerQueued;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiMatchmakerRemoved OnMatchmakerRemoved;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiChatReceived OnChatReceived;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiChatJoined OnChatJoined;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiChatLeft OnChatLeft;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiNotificationReceived OnNotificationReceived;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiPresenceUpdated OnPresenceUpdated;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiVoteCastOk OnVoteCastOk;

	UPROPERTY(BlueprintAssignable, Category = "Asobi|WebSocket")
	FOnAsobiVoteVetoOk OnVoteVetoOk;

private:
	void Send(const FString& Type, const TSharedPtr<FJsonObject>& Payload);
	void HandleMessage(const FString& MessageString);
	FString SerializeJson(const TSharedPtr<FJsonObject>& Obj);

	TSharedPtr<IWebSocket> WebSocket;
	int32 NextCid = 1;
};

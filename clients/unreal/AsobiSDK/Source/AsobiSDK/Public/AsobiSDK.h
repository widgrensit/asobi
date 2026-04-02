#pragma once

#include "Modules/ModuleManager.h"

class FAsobiSDKModule : public IModuleInterface
{
public:
	virtual void StartupModule() override;
	virtual void ShutdownModule() override;
};

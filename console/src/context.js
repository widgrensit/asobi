import { createContext, useContext } from 'react';

// What an extension's screen may ask the console about itself. Read-only and
// deliberately small: the actor it is rendering for, what the node reports as
// installed, and the resolved registry. Anything else an extension needs it
// fetches from its own ops actions.
export const ConsoleContext = createContext({
  actor: null,
  features: null,
  extensions: [],
});

export function useConsole() {
  return useContext(ConsoleContext);
}

export function useActor() {
  return useContext(ConsoleContext).actor;
}

export function useFeatures() {
  return useContext(ConsoleContext).features;
}

// Whether this node has a named capability, core's or an extension's. A screen
// that renders a Steam column should ask rather than assume, because one
// composed bundle serves deployments that differ.
export function useCapability(name) {
  const features = useFeatures();
  if (!features) return false;
  const all = [features.core, ...(features.extensions || [])];
  return all.some((entry) => (entry.capabilities || []).some((cap) => cap.name === name && cap.enabled));
}

// Names of the extensions the node reports installed.
export function installedNames(features) {
  if (!features || !Array.isArray(features.extensions)) return null;
  return features.extensions.map((extension) => extension.name);
}

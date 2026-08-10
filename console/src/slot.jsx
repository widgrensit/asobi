import { Component } from 'react';
import { useConsole } from './context.js';
import { slotEntries } from './registry.js';

// This module imports no screen, so a core screen can render a slot and an
// extension route can reuse the boundary without the two importing each other.

// An extension's screen is compiled into this bundle, so a throw in one takes
// the whole console down with it - including the core screens an operator
// needs during the incident that produced the bad data in the first place.
// That is the one failure this boundary exists for.
export class Boundary extends Component {
  constructor(props) {
    super(props);
    this.state = { failed: null };
  }

  static getDerivedStateFromError(error) {
    return { failed: error };
  }

  render() {
    if (!this.state.failed) return this.props.children;
    return (
      <div className="banner banner-error" role="alert">
        <div className="banner-head">
          <code className="code">{this.props.name}</code>
          <span>This extension&rsquo;s screen failed to render. The rest of the console is unaffected.</span>
        </div>
        <pre className="pre">{String(this.state.failed && this.state.failed.message)}</pre>
      </div>
    );
  }
}

// A named place in a core screen an extension may add to, for the case that is
// not a new page: a clan panel belongs on the player an operator is already
// looking at, not behind another click.
//
// `ctx` is the promise the slot id carries, so adding an id to SLOTS is a
// contract change and changing what an existing id passes is a breaking one.
export function Slot({ id, ctx }) {
  const { extensions } = useConsole();
  const entries = slotEntries(extensions, id);
  if (entries.length === 0) return null;
  return entries.map(({ name, Component: Panel }) => (
    <Boundary key={name} name={name}>
      <Panel {...ctx} />
    </Boundary>
  ));
}

package ghcvm.runtime.message;

import ghcvm.runtime.closure.StgClosure;

public class Message extends StgClosure {
    public boolean isValid() { return false; }
}

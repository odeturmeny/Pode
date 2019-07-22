# Logging to Terminal

## Setup

This tutorial will be short and sweet! To start logging requests to your server onto the terminal, you simply do the following:

```powershell
Start-PodeServer {
    Add-PodeEndpoint -Address *:8080 -Protocol Http

    # just this line!
    logger terminal
}
```

And that's it, done!
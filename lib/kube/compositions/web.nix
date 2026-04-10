# mkWeb — Frontend + BFF composition (HTTP + WebSocket dual port).
#
# Identical to mkMicroservice but with dual-port defaults.
#
# Pure function — no pkgs dependency.
let
  micro = import ./microservice.nix;
in rec {
  mkWeb = args: micro.mkMicroservice ({
    ports = [
      { name = "http"; containerPort = 8080; protocol = "TCP"; }
      { name = "ws"; containerPort = 8081; protocol = "TCP"; }
    ];
    service = {
      type = "ClusterIP";
      ports = [
        { name = "http"; port = 8080; targetPort = "http"; }
        { name = "ws"; port = 8081; targetPort = "ws"; }
      ];
    };
  } // args);
}

terraform {
  required_version = ">= 0.13"

  required_providers {
    ct = {
     source  = "poseidon/ct"
     version = "0.7.1"
    }
    matchbox = {
      source  = "poseidon/matchbox"
      version = "0.4.1"
    }
  }
}

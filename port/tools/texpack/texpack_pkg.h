// texpack_pkg.h: package access for the texpack tool (implemented with the engine's FileIO module).
#pragma once
#include <vector>
#include <utility>

bool PkgOpen(const char *path);
void PkgList(std::vector<std::pair<int, unsigned>> *out);   // file ID, size in bytes
bool PkgRead(int id, std::vector<unsigned char> *out);
